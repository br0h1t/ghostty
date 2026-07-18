import AppKit
import CoreText
import UniformTypeIdentifiers
import GhosttyKit

// MARK: NSDraggingDestination

extension Ghostty.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
    ]

    final class DndState {
        /// The bytes for an offered MIME type.
        enum DropData {
            case memory(Data)
            case file(URL)
        }

        /// True while the client has registered as a drop target (`t=a`); when
        /// false, native drops fall back to the legacy path/text paste.
        var accepting = false
        /// Multiplexer session id from the client's last `t=a`, or -1 if unset.
        var session: Int32 = -1
        /// The MIME types last offered to the client via `t=m`/`t=M`.
        var offeredMimes: [String] = []
        /// Native source operation mask from the current drag (bit 0 = copy, 1 = move).
        var allowedOperations: Int32 = 0
        /// Data source for each offered MIME type, from the current drop.
        var dropData: [String: DropData] = [:]
        /// The drag operation the client last said it would perform.
        var clientOperation: NSDragOperation = []
        /// The client's ordered preference list from its last `t=m:o=` response.
        var clientMimes: [String] = []
        /// True while file promises for the current drop are still resolving
        var promisesPending = false
        /// `t=r` requests deferred until pending file promises resolve.
        var pendingRequests: [Int32] = []
        /// Temp dir file promises materialize into.
        var tempDir: URL?
        /// Bumped per drop (and on reset) so a late promise completion or
        /// in-flight data stream from a superseded drop is detected and dropped.
        var generation: UInt = 0

        func reset() {
            clientOperation = []
            offeredMimes = []
            allowedOperations = 0
            clientMimes = []
            dropData = [:]
            pendingRequests = []
            promisesPending = false
            generation &+= 1
            if let tempDir {
                try? FileManager.default.removeItem(at: tempDir)
                self.tempDir = nil
            }
        }
    }

    /// Max raw bytes handed to a single `ghostty_surface_dnd_data` call while
    /// streaming. Drop data (a promised file) may be very large, so it is
    /// streamed in bounded chunks, yielding to the run loop between them.
    private static let dndStreamChunkSize = 64 * 1024

    // Kitty DnD: On drag enter, we start off refusing to accept the drop. When the client
    // informs us of the operation it will perform, it will be forwarded via `draggingUpdated`.
    // This is facilitated by opting-in to `wantsPeriodicDraggingUpdates`

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dndState.accepting else { return validateDragOperation(sender) }

        dndState.clientOperation = []
        dndState.offeredMimes = Self.dndMimeList(for: sender.draggingPasteboard)
        dndState.allowedOperations = Self.dndAllowedOperations(sender)

        sendDndPointer(kind: .enter, sender: sender)
        return dndState.clientOperation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dndState.accepting else { return validateDragOperation(sender) }

        dndState.allowedOperations = Self.dndAllowedOperations(sender)
        sendDndPointer(kind: .move, sender: sender)
        return dndState.clientOperation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard dndState.accepting, let surface else { return }

        ghostty_surface_dnd_leave(surface, dndState.session)
        dndState.reset()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dndState.accepting else { return insertDroppedContentsAsText(sender) }
        guard let surface else { return false }
        guard !dndState.clientOperation.isEmpty else { return false }
        guard !dndState.offeredMimes.isEmpty else { return false }

        // The drag pasteboard is only valid for the duration of this call, so
        // every offered type's data is snapshotted now. The client's `t=r`
        // requests arrive asynchronously later.
        let pasteboard = sender.draggingPasteboard
        dndState.generation &+= 1
        dndState.pendingRequests = []
        dndSnapshotData(from: pasteboard)

        let point = convert(sender.draggingLocation, from: nil)
        dndState.allowedOperations = Self.dndAllowedOperations(sender)
        dndState.offeredMimes.joined(separator: " ").withCString { ptr in
            ghostty_surface_dnd_drop(
                surface,
                dndState.session,
                point.x, frame.height - point.y,
                dndState.allowedOperations,
                ptr)
        }
        return true
    }

    private func validateDragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    private func insertDroppedContentsAsText(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content = pb.getOpinionatedStringContents()

        if let content {
            DispatchQueue.main.async {
                self.insertText(
                    content,
                    replacementRange: NSRange(location: 0, length: 0)
                )
            }
            return true
        }

        return false
    }

    private enum DndPointerKind {
        case enter, move
    }

    /// The set of operations the OS drag source permits, encoded as the protocol's
    /// `o=` value (bit 0 = copy, bit 1 = move) that we advertise to the client.
    private static func dndAllowedOperations(_ sender: any NSDraggingInfo) -> Int32 {
        let mask = sender.draggingSourceOperationMask
        var ops: Int32 = 0
        if mask.contains(.copy) { ops |= 1 }
        if mask.contains(.move) { ops |= 2 }
        if mask.contains(.generic) { ops |= 3 }
        return ops
    }

    /// Maps a protocol operation value (1 = copy, 2 = move) to the corresponding `NSDragOperation`
    private static func nsDragOperation(from operation: Int32) -> NSDragOperation {
        switch operation {
        case 1: return .copy
        case 2: return .move
        default: return []
        }
    }

    private func sendDndPointer(kind: DndPointerKind, sender: any NSDraggingInfo) {
        guard let surface else { return }
        let point = convert(sender.draggingLocation, from: nil)
        let x = point.x
        let y = frame.height - point.y
        let ops = dndState.allowedOperations

        switch kind {
        case .enter:
            dndState.offeredMimes.joined(separator: " ").withCString { ptr in
                ghostty_surface_dnd_enter(surface, dndState.session, x, y, ops, ptr)
            }
        case .move:
            ghostty_surface_dnd_move(surface, dndState.session, x, y, ops, nil)
        }
    }

    /// Builds the ordered, de-duplicated list of MIME types available on the
    /// drag pasteboard, for the `t=m`/`t=M` offered-mimes list.
    private static func dndMimeList(for pasteboard: NSPasteboard) -> [String] {
        var seen = Set<String>()
        var mimes: [String] = []
        func add(_ mime: String?) {
            guard let mime, !mime.isEmpty, seen.insert(mime).inserted else { return }
            mimes.append(mime)
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types { add(type.dndMimeType) }
        }

        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        for receiver in receivers {
            for uti in receiver.fileTypes {
                add(NSPasteboard.PasteboardType(uti).dndMimeType)
            }
        }
        return mimes
    }

    private func dndSnapshotData(from pasteboard: NSPasteboard) {
        dndState.dropData = [:]

        if let texts = pasteboard.readObjects(
            forClasses: [NSString.self], options: nil) as? [String], !texts.isEmpty,
           let data = texts.joined(separator: "\n").data(using: .utf8) {
            dndState.dropData["text/plain"] = .memory(data)
        }

        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        let baseURIStrings = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL])?.map(\.absoluteString) ?? []
        if receivers.isEmpty {
            if let list = Self.encodeURIList(baseURIStrings) {
                dndState.dropData["text/uri-list"] = .memory(list)
            }
        } else {
            dndResolvePromises(receivers, baseURIStrings: baseURIStrings, generation: dndState.generation)
        }

        for type in pasteboard.types ?? [] {
            guard let mime = type.dndMimeType,
                  mime != "text/uri-list", mime != "text/plain",
                  dndState.dropData[mime] == nil,
                  let data = pasteboard.data(forType: type) else { continue }
            dndState.dropData[mime] = .memory(data)
        }
    }

    /// Encodes a list of URL strings as an RFC 2483 `text/uri-list` payload.
    private static func encodeURIList(_ urlStrings: [String]) -> Data? {
        guard !urlStrings.isEmpty else { return nil }
        return (urlStrings.joined(separator: "\r\n") + "\r\n").data(using: .utf8)
    }

    /// Resolves a collection of drag and drop file promises into a temporary directory.
    /// Promises that resolve to a fileURL type are merged with the baseURIStrings into a `text/uri-list` payload.
    /// Others are stored as a file path  and streamed when the client demands it via `dndServe`
    private func dndResolvePromises( _ receivers: [NSFilePromiseReceiver], baseURIStrings: [String], generation: UInt) {
        guard let tempDir = try? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        ) else {
            Ghostty.logger.warning("dnd: failed to create temp dir for file promises")
            if let list = Self.encodeURIList(baseURIStrings) {
                dndState.dropData["text/uri-list"] = .memory(list)
            }
            return
        }

        dndState.tempDir = tempDir
        dndState.promisesPending = true

        let queue = OperationQueue()
        let group = DispatchGroup()
        var uriStrings = baseURIStrings

        for receiver in receivers {
            let fileTypes = receiver.fileTypes
            let isFileURL = fileTypes.contains { UTType($0)?.conforms(to: .fileURL) ?? false }
            group.enter()
            receiver.receivePromisedFiles(
                atDestination: tempDir,
                options: [:],
                operationQueue: queue
            ) { [weak self] fileURL, error in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self, self.dndState.generation == generation else { return }
                    if let error {
                        Ghostty.logger.warning(
                            "dnd: file promise failed error=\(error.localizedDescription, privacy: .public)")
                        return
                    }
                    if isFileURL {
                        uriStrings.append(fileURL.absoluteString)
                    } else {
                        for uti in fileTypes {
                            guard let mime = NSPasteboard.PasteboardType(uti).dndMimeType,
                                  self.dndState.dropData[mime] == nil else { continue }
                            self.dndState.dropData[mime] = .file(fileURL)
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.dndState.generation == generation else { return }
            if let list = Self.encodeURIList(uriStrings) {
                self.dndState.dropData["text/uri-list"] = .memory(list)
            }
            self.dndState.promisesPending = false
            self.dndDispatchPendingRequests()
        }
    }

    /// Re-dispatches `t=r` requests that were deferred while file promises were still resolving.
    private func dndDispatchPendingRequests() {
        let pending = dndState.pendingRequests
        dndState.pendingRequests = []
        for mimeIndex in pending {
            dndRequestData(mimeIndex: mimeIndex)
        }
    }

    /// The client registered as a drop target (`t=a`).
    func dndAccept(mimes: String, session: Int32) {
        dndState.accepting = true
        dndState.session = session

        var types = Self.dropTypes
        for mime in mimes.split(separator: " ") {
            if let type = NSPasteboard.PasteboardType(dndMimeType: String(mime)) {
                types.insert(type)
            }
        }
        types.formUnion(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        registerForDraggedTypes(Array(types))
    }

    /// The client responded to a pointer event with the operation it will perform if
    /// the drop occurs (`t=m:o=`). This is relayed to the OS via `draggingUpdated`.
    func dndSetOperation(operation: Int32, mimes: String) {
        let operationAllowed = (operation & dndState.allowedOperations) == operation
        let mimeList = mimes.split(whereSeparator: \.isWhitespace).map(String.init)
        let mimesAllowed = Set(mimeList).isSubset(of: dndState.offeredMimes)

        guard operationAllowed && mimesAllowed else {
            return
        }

        dndState.clientOperation = Self.nsDragOperation(from: operation)
        if !mimeList.isEmpty {
            dndState.clientMimes = mimeList
        }
    }

    /// The client unregistered as a drop target (`t=A`).
    func dndStop() {
        dndState.accepting = false
        dndState.session = -1
        dndState.reset()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    func dndRequestData(mimeIndex: Int32) {
        guard let surface else { return }
        let session = dndState.session

        let index = Int(mimeIndex) - 1
        guard dndState.offeredMimes.indices.contains(index) else {
            ghostty_surface_dnd_data_error(surface, mimeIndex, session, "ENOENT", nil)
            return
        }
        let mime = dndState.offeredMimes[index]

        guard let source = dndState.dropData[mime] else {
            if dndState.promisesPending {
                dndState.pendingRequests.append(mimeIndex)
            } else {
                ghostty_surface_dnd_data_error(surface, mimeIndex, session, "ENOENT", nil)
            }
            return
        }

        dndServe(source, mimeIndex: mimeIndex, generation: dndState.generation)
    }

    /// Streams a drop-data source to the client in bounded chunks, yielding to the run loop between them.
    /// A generation mismatch (drop superseded or reset) aborts the stream.
    private func dndServe(_ source: DndState.DropData, mimeIndex: Int32, generation: UInt) {
        switch source {
        case .memory(let data):
            dndStreamMemory(data, offset: 0, mimeIndex: mimeIndex, generation: generation)

        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                if let surface {
                    ghostty_surface_dnd_data_error(surface, mimeIndex, dndState.session, "ENOENT", nil)
                }
                return
            }
            dndStreamFile(handle, mimeIndex: mimeIndex, generation: generation)
        }
    }

    private func dndStreamMemory(_ payload: Data, offset: Int, mimeIndex: Int32, generation: UInt) {
        guard dndState.generation == generation, let surface else { return }
        let session = dndState.session

        guard offset < payload.count else {
            ghostty_surface_dnd_data_eof(surface, mimeIndex, session)
            return
        }

        let nextOffset = min(offset + Self.dndStreamChunkSize, payload.count)
        payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress?.advanced(by: offset)
            ghostty_surface_dnd_data(surface, mimeIndex, session, baseAddress, UInt(nextOffset - offset))
        }

        DispatchQueue.main.async { [weak self] in
            self?.dndStreamMemory(payload, offset: nextOffset, mimeIndex: mimeIndex, generation: generation)
        }
    }

    private func dndStreamFile(_ fileHandle: FileHandle, mimeIndex: Int32, generation: UInt) {
        guard dndState.generation == generation, let surface else {
            try? fileHandle.close()
            return
        }
        let session = dndState.session

        let fileBytes: Data
        do {
            fileBytes = try fileHandle.read(upToCount: Self.dndStreamChunkSize) ?? Data()
        } catch {
            ghostty_surface_dnd_data_error(surface, mimeIndex, session, "EIO", nil)
            try? fileHandle.close()
            return
        }

        guard !fileBytes.isEmpty else {
            ghostty_surface_dnd_data_eof(surface, mimeIndex, session)
            try? fileHandle.close()
            return
        }

        fileBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress
            ghostty_surface_dnd_data(surface, mimeIndex, session, baseAddress, UInt(fileBytes.count))
        }

        DispatchQueue.main.async { [weak self] in
            self?.dndStreamFile(fileHandle, mimeIndex: mimeIndex, generation: generation)
        }
    }

    /// The client signaled the drop transfer is complete (`t=r:o=`)
    func dndFinish(operation: Int32) {
        let finalOperation = Self.nsDragOperation(from: operation)
        if finalOperation != dndState.clientOperation {
            Ghostty.logger.debug("dnd finish operation mismatch: final=\(operation, privacy: .public)")
        }

        dndState.reset()
    }
}

// MARK: NSDraggingSource

extension Ghostty.SurfaceView {
    /// Owns the terminal-as-drag-source half of OSC 72
    final class DragController: NSObject, NSDraggingSource {
        enum Phase: Equatable {
            case disabled
            case awaitingGesture
            case awaitingOffer
            case buildingOffer
            case nativeDrag
            case finishing
        }

        struct ImageMetadata {
            let index: Int32
            let format: Int32
            let width: Int32
            let height: Int32
            let opacity: Int32
        }

        enum DragError: String, Error {
            case EPERM
            case EINVAL
            case ETIMEDOUT
        }

        enum DragImageDecodeResult {
            case image(NSImage)
            case invalid
        }

        enum LazyResult {
            case pending
            case data(Data)
            case failed
            case timedOut
        }

        final class LazyRequest {
            private(set) var result: LazyResult = .pending
            var sent = false

            func resolve(_ data: Data) {
                result = .data(data)
            }

            func fail() {
                result = .failed
            }

            func wait(timeout: TimeInterval, while isValid: () -> Bool) -> LazyResult {
                let deadline = Date().addingTimeInterval(timeout)
                while case .pending = result {
                    guard isValid() else {
                        result = .failed
                        break
                    }
                    guard Date() < deadline else {
                        result = .timedOut
                        break
                    }
                    _ = RunLoop.current.run(
                        mode: .default,
                        before: min(deadline, Date().addingTimeInterval(0.02)))
                }
                return result
            }
        }

        private final class PasteboardProvider: NSObject, NSPasteboardItemDataProvider {
            weak var owner: DragController?
            let generation: UInt
            let mimeIndex: Int

            init(owner: DragController, generation: UInt, mimeIndex: Int) {
                self.owner = owner
                self.generation = generation
                self.mimeIndex = mimeIndex
            }

            func pasteboard(
                _ pasteboard: NSPasteboard?,
                item: NSPasteboardItem,
                provideDataForType type: NSPasteboard.PasteboardType
            ) {
                owner?.provideData(for: item, type: type, mimeIndex: mimeIndex, generation: generation)
            }
        }

        /// Maximum time for clients to fulfill a lazy data request
        private static let providerTimeout: TimeInterval = 5
        /// Distance from the bottom of the drag image to the mouse pointer
        private static let dragImageBottomPadding: CGFloat = 10
        /// Minimum pointer movement to trigger a drag gesture
        private static let gestureThreshold: CGFloat = 5

        private weak var surfaceView: Ghostty.SurfaceView?
        /// Current drag-source lifecycle phase.
        private(set) var phase: Phase = .disabled
        /// Bumped per offer so stale lazy completions from a superseded drag are ignored.
        private(set) var generation: UInt = 0
        /// True after the client registered this pane as a drag source (`t=o:x=1`).
        private var registered = false
        /// Multiplexer session id from the client's registration, or -1 if unset.
        private var session: Int32 = -1
        /// True while the mouse button is down on a registered drag source.
        private var mouseIsDown = false
        /// Mouse-down event retained until a gesture threshold is crossed.
        private var mouseDownEvent: NSEvent?
        /// Last mouse-dragged event used to start the native dragging session.
        private var dragEvent: NSEvent?
        /// MIME types offered by the application for the current drag.
        private var mimes: [String] = []
        /// Native drag operations allowed by the client's `t=o:o=` flags.
        private var operationMask: NSDragOperation = []
        /// Eager `t=p` payload bytes keyed by MIME index.
        private var preSentData: [Int: Data] = [:]
        /// Decoded drag images from pre-sent `t=p:x<0` sequences.
        private var images: [NSImage] = []
        /// Outstanding lazy data requests keyed by MIME index.
        private var requests: [Int: LazyRequest] = [:]
        /// Pasteboard data providers for MIME types without eager data.
        private var providers: [PasteboardProvider] = []
        /// AppKit dragging session for the active native drag, if any.
        private var draggingSession: NSDraggingSession?

        func attach(to surfaceView: Ghostty.SurfaceView) {
            self.surfaceView = surfaceView
        }

        func close() {
            registered = false
            clearOffer(next: .disabled)
            surfaceView = nil
        }

        func reset() {
            registered = false
            session = -1
            clearOffer(next: .disabled)
        }

        func abort() {
            switch phase {
            case .nativeDrag, .finishing:
                operationMask = []
                for request in requests.values {
                    request.fail()
                }
                phase = .finishing
                updateDraggingImage(nil)

            case .awaitingOffer, .buildingOffer:
                clearOffer(next: registered ? .awaitingGesture : .disabled)

            default:
                break
            }
        }

        func setRegistration(enabled: Bool, session: Int32 = -1) {
            registered = enabled
            self.session = enabled ? session : -1
            clearOffer(next: enabled ? .awaitingGesture : .disabled)
        }

        func mouseDown(with event: NSEvent) {
            guard phase == .awaitingGesture else { return }
            mouseIsDown = true
            mouseDownEvent = event
        }

        func mouseUp(with _: NSEvent) {
            mouseIsDown = false
            mouseDownEvent = nil

            switch phase {
            case .awaitingOffer, .buildingOffer:
                rejectOffer(.EPERM)

            default:
                break
            }
        }

        func mouseDragged(with event: NSEvent) {
            guard phase == .awaitingGesture, mouseIsDown, let mouseDownEvent,
                  let surfaceView else { return }
            guard Self.exceedsGestureThreshold(from: mouseDownEvent, to: event) else {
                return
            }

            dragEvent = event
            phase = .awaitingOffer
            surfaceView.dndSendPrompt(event: event, session: session)
        }

        static func exceedsGestureThreshold(from start: NSEvent, to current: NSEvent) -> Bool {
            let dx = current.locationInWindow.x - start.locationInWindow.x
            let dy = current.locationInWindow.y - start.locationInWindow.y
            return dx * dx + dy * dy >= gestureThreshold * gestureThreshold
        }

        func keyDown(with event: NSEvent) -> Bool {
            guard event.keyCode == 53 else { return false }
            switch phase {
            case .awaitingOffer, .buildingOffer:
                rejectOffer(.EPERM)
                return true

            default:
                return false
            }
        }

        func receiveOffer(mimes: String, operations: Int32) {
            guard phase == .awaitingOffer, mouseIsDown else {
                rejectOffer(.EPERM)
                return
            }

            self.mimes = mimes.split(whereSeparator: \.isWhitespace).map(String.init)
            generation &+= 1
            operationMask = Self.dragOperation(for: operations)
            preSentData = [:]
            images = []
            requests = [:]
            providers = []
            draggingSession = nil
            phase = .buildingOffer
        }

        func receivePreSentData(index: Int32, data: Data) {
            guard phase == .buildingOffer else {
                rejectOffer(.EPERM)
                return
            }

            let mimeIndex = Int(index)
            guard mimes.indices.contains(mimeIndex), preSentData[mimeIndex] == nil else {
                rejectOffer(.EINVAL)
                return
            }
            preSentData[mimeIndex] = data
        }

        func receivePreSentImage(_ metadata: ImageMetadata, data: Data) {
            guard phase == .buildingOffer else {
                rejectOffer(.EPERM)
                return
            }

            guard Int(metadata.index) == images.count else {
                rejectOffer(.EINVAL)
                return
            }

            switch decodeDragImage(
                data: data,
                format: metadata.format,
                width: metadata.width,
                height: metadata.height,
                opacity: metadata.opacity
            ) {
            case .image(let image):
                images.append(image)
            case .invalid:
                rejectOffer(.EINVAL)
            }
        }

        func receiveStartDrag() {
            guard phase == .buildingOffer, mouseIsDown else {
                rejectOffer(.EPERM)
                return
            }
            startNativeDrag()
        }

        func receiveImageSelect(index: Int32) {
            guard phase == .nativeDrag else {
                rejectOffer(.EINVAL)
                return
            }

            let selected = Int(index)
            updateDraggingImage(images.indices.contains(selected) ? images[selected] : nil)
        }

        func receiveLazyData(index: Int32, data: Data) {
            guard phase == .nativeDrag || phase == .finishing else {
                rejectOffer(.EINVAL)
                return
            }

            let mimeIndex = Int(index)
            guard let request = requests[mimeIndex], request.sent else {
                abortDrag(.EINVAL)
                return
            }
            request.resolve(data)
        }

        func receiveError(index: Int32, payload: String) {
            guard phase == .nativeDrag || phase == .finishing else {
                rejectOffer(.EINVAL)
                return
            }
            guard let request = requests[Int(index)], request.sent else {
                abortDrag(.EINVAL)
                return
            }
            request.fail()
        }

        func receiveCancel() {
            switch phase {
            case .nativeDrag, .finishing:
                operationMask = []
                for request in requests.values {
                    request.fail()
                }
                phase = .finishing
                updateDraggingImage(nil)

            case .awaitingOffer, .buildingOffer:
                clearOffer(next: registered ? .awaitingGesture : .disabled)

            default:
                break
            }
        }

        static func dragOperation(for flags: Int32) -> NSDragOperation {
            var result: NSDragOperation = []
            if flags & 1 != 0 { result.insert(.copy) }
            if flags & 2 != 0 { result.insert(.move) }
            return result
        }

        static func operationCode(for operation: NSDragOperation) -> Int32 {
            var result: Int32 = 0
            if operation.contains(.copy) { result |= 1 }
            if operation.contains(.move) { result |= 2 }
            return result
        }

        static func localURLs(fromURIList data: Data) -> [URL]? {
            guard let value = String(data: data, encoding: .utf8) else { return nil }
            let urls = value
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> URL? in
                    let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, !value.hasPrefix("#"),
                          let url = URL(string: value), url.isFileURL,
                          url.host == nil || url.host == "" || url.host == "localhost" else {
                        return nil
                    }
                    return url
                }
            return urls.isEmpty ? nil : urls
        }

        private func decodeDragImage(
            data: Data,
            format: Int32,
            width: Int32,
            height: Int32,
            opacity: Int32
        ) -> DragImageDecodeResult {
            if format == 0 {
                return decodeTextImage(
                    data: data,
                    widthUnits: Int(width),
                    heightUnits: Int(height),
                    opacity: opacity
                )
            }

            let pixelWidth = Int(width)
            let pixelHeight = Int(height)
            let samples: Int
            let hasAlpha: Bool
            let scale = surfaceView?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 1

            switch format {
            case 24:
                samples = 3
                hasAlpha = false
            case 32:
                samples = 4
                hasAlpha = true
            case 100:
                guard let rep = NSBitmapImageRep(data: data),
                      rep.pixelsWide == pixelWidth, rep.pixelsHigh == pixelHeight else { return .invalid }
                let image = NSImage(
                    size: NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
                )
                image.addRepresentation(rep)
                return .image(image)
            default:
                return .invalid
            }

            let (pixels, pixelOverflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
            let (expectedBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: samples)
            guard !pixelOverflow, !byteOverflow else { return .invalid }
            guard expectedBytes == data.count else { return .invalid }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: data as CFData) else { return .invalid }

            let alphaInfo: CGImageAlphaInfo = hasAlpha ? .last : .none
            guard let cgImage = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: samples * 8,
                bytesPerRow: pixelWidth * samples,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else { return .invalid }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
            )
            return .image(image)
        }

        private func decodeTextImage(
            data: Data,
            widthUnits: Int,
            heightUnits: Int,
            opacity: Int32
        ) -> DragImageDecodeResult {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return .invalid
            }

            let scale = CGFloat(widthUnits) / CGFloat(heightUnits)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: dragTextFont(scale: scale),
                .foregroundColor: NSColor.labelColor,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let bounds = attributed.boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                             height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            let line = CTLineCreateWithAttributedString(attributed)
            let inkMaxX = CTLineGetImageBounds(line, nil).maxX

            let width = ceil(max(bounds.width, inkMaxX))
            let height = ceil(bounds.height)
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                return .invalid
            }

            let imageSize = NSSize(width: width, height: height + Self.dragImageBottomPadding)
            let image = NSImage(size: imageSize, flipped: false) { rect in
                if opacity > 0 {
                    let alpha = CGFloat(opacity) / 1024.0
                    NSColor.windowBackgroundColor.withAlphaComponent(alpha).setFill()
                    rect.fill()
                }
                attributed.draw(at: NSPoint(x: 0, y: Self.dragImageBottomPadding))
                return true
            }
            return .image(image)
        }

        private func dragTextFont(scale: CGFloat) -> NSFont {
            var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            guard let surface = surfaceView?.surface else { return font }
            if let fontRaw = ghostty_surface_quicklook_font(surface) {
                let unmanaged = Unmanaged<CTFont>.fromOpaque(fontRaw)
                font = unmanaged.takeUnretainedValue() as NSFont
                unmanaged.release()
            }
            var descriptor = font.fontDescriptor
            if let symbolsRaw = ghostty_surface_symbols_font(surface) {
                let unmanaged = Unmanaged<CTFont>.fromOpaque(symbolsRaw)
                let symbolsFont = unmanaged.takeUnretainedValue() as NSFont
                unmanaged.release()
                descriptor = descriptor.addingAttributes([.cascadeList: [symbolsFont.fontDescriptor]])
            }
            return NSFont(descriptor: descriptor, size: font.pointSize * scale) ?? font
        }

        private func startNativeDrag() {
            guard let surfaceView,
                  let event = dragEvent,
                  let items = buildDraggingItems(at: surfaceView.convert(event.locationInWindow, from: nil)),
                  !items.isEmpty else {
                rejectOffer(.EINVAL)
                return
            }

            phase = .nativeDrag
            draggingSession = surfaceView.beginDraggingSession(with: items, event: event, source: self)
            draggingSession?.animatesToStartingPositionsOnCancelOrFail = true

            surfaceView.dndDragWillBegin(with: event)
            surfaceView.dndSendStartResult(code: "OK", session: session)
        }

        private func buildDraggingItems(at point: NSPoint) -> [NSDraggingItem]? {
            var result: [NSDraggingItem] = []
            var genericItem: NSPasteboardItem?
            var genericTypes = Set<NSPasteboard.PasteboardType>()

            for (index, mime) in mimes.enumerated() {
                if mime == "text/uri-list", let data = preSentData[index],
                   let urls = Self.localURLs(fromURIList: data) {
                    for url in urls {
                        result.append(NSDraggingItem(pasteboardWriter: url as NSURL))
                    }
                    continue
                }

                guard let type = NSPasteboard.PasteboardType(dndMimeType: mime),
                      genericTypes.insert(type).inserted else { continue }
                let item = genericItem ?? NSPasteboardItem()
                genericItem = item

                if let data = preSentData[index] {
                    guard Self.setRepresentation(data, mime: mime, type: type, on: item) else {
                        return nil
                    }
                } else {
                    let provider = PasteboardProvider(owner: self, generation: generation, mimeIndex: index)
                    providers.append(provider)
                    item.setDataProvider(provider, forTypes: [type])
                }
            }

            if let genericItem {
                result.insert(NSDraggingItem(pasteboardWriter: genericItem), at: 0)
            }
            guard !result.isEmpty else { return nil }

            let image = images.first ?? Self.fallbackDragImage
            for (index, item) in result.enumerated() {
                Self.applyDragImage(image, to: item, isPrimary: index == 0, anchor: point)
            }
            return result
        }

        private static func setRepresentation(
            _ data: Data,
            mime: String,
            type: NSPasteboard.PasteboardType,
            on item: NSPasteboardItem
        ) -> Bool {
            if mime == "text/plain" {
                guard let value = String(data: data, encoding: .utf8) else { return false }
                return item.setString(value, forType: type)
            }

            return item.setData(data, forType: type)
        }

        private func provideData(
            for item: NSPasteboardItem,
            type: NSPasteboard.PasteboardType,
            mimeIndex: Int,
            generation: UInt
        ) {
            guard generation == self.generation, phase == .nativeDrag,
                  mimes.indices.contains(mimeIndex), let surfaceView else { return }

            let request = requests[mimeIndex] ?? LazyRequest()
            requests[mimeIndex] = request
            if !request.sent {
                request.sent = true
                surfaceView.dndSendDataRequest(index: Int32(mimeIndex), session: session)
            }

            let result = request.wait(timeout: Self.providerTimeout) {
                generation == self.generation && (phase == .nativeDrag || phase == .finishing)
            }
            if case .data(let data) = result {
                _ = Self.setRepresentation(data, mime: mimes[mimeIndex], type: type, on: item)
            } else if case .timedOut = result {
                request.fail()
                surfaceView.dndSendOfferError(
                    index: Int32(mimeIndex),
                    code: DragError.ETIMEDOUT.rawValue,
                    session: session)
            }
        }

        /// Applies a drag preview to one item. The primary item shows `image`
        /// anchored at `anchor` when starting a drag, or keeps its frame origin
        /// when updating an active session. Secondary items are given an empty
        /// frame to prevent them from showing their own default previews.
        private static func applyDragImage(
            _ image: NSImage,
            to item: NSDraggingItem,
            isPrimary: Bool,
            anchor: NSPoint? = nil
        ) {
            let frame: NSRect
            guard isPrimary else {
                frame = NSRect(origin: .zero, size: NSSize(width: 1, height: 1))
                item.setDraggingFrame(frame, contents: nil)
                return
            }
            if let anchor {
                frame = NSRect(origin: anchor, size: image.size)
            } else {
                var existing = item.draggingFrame
                existing.size = image.size
                frame = existing
            }
            item.setDraggingFrame(frame, contents: image)
        }

        private func updateDraggingImage(_ image: NSImage?) {
            guard let draggingSession else { return }
            let content = image ?? Self.transparentDragImage
            draggingSession.enumerateDraggingItems(
                options: [],
                for: nil,
                classes: [NSPasteboardItem.self, NSURL.self],
                searchOptions: [:]
            ) { item, index, stop in
                Self.applyDragImage(content, to: item, isPrimary: index == 0)
                if index == 0 {
                    stop.pointee = true
                }
            }
        }

        private func abortDrag(_ error: DragError) {
            operationMask = []
            for request in requests.values {
                request.fail()
            }
            if phase == .nativeDrag {
                phase = .finishing
                updateDraggingImage(nil)
            }
            surfaceView?.dndSendAbortDrag(code: error.rawValue, session: session)
            clearOffer(next: registered ? .awaitingGesture : .disabled)
        }

        private func rejectOffer(_ error: DragError) {
            surfaceView?.dndSendStartResult(code: error.rawValue, session: session)
            clearOffer(next: registered ? .awaitingGesture : .disabled)
        }

        private func clearOffer(next: Phase) {
            generation &+= 1
            phase = next
            mouseIsDown = false
            mouseDownEvent = nil
            dragEvent = nil
            mimes = []
            operationMask = []
            preSentData = [:]
            images = []
            for request in requests.values {
                request.fail()
            }
            requests = [:]
            providers = []
            draggingSession = nil
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor _: NSDraggingContext
        ) -> NSDragOperation {
            if let draggingSession, draggingSession !== session { return [] }
            guard phase == .nativeDrag else { return [] }
            return operationMask
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt _: NSPoint,
            operation: NSDragOperation
        ) {
            guard draggingSession === session else { return }

            phase = .finishing
            let code = Self.operationCode(for: operation)
            if code != 0 {
                surfaceView?.dndSendAction(operation: code, session: self.session)
                surfaceView?.dndSendDropped(session: self.session)
            }
            surfaceView?.dndSendFinished(cancelled: code == 0, session: self.session)
            clearOffer(next: registered ? .awaitingGesture : .disabled)
        }

        // TODO: This is a placeholder. We should ideally have a better fallback image
        private static let fallbackDragImage: NSImage = {
            let size = NSSize(width: 64, height: 48)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
            image.unlockFocus()
            return image
        }()

        private static let transparentDragImage: NSImage = {
            NSImage(size: NSSize(width: 1, height: 1))
        }()
    }

    func dndSendPrompt(event: NSEvent, session: Int32) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_dnd_prompt(surface, session, point.x, frame.height - point.y)
    }

    func dndSendStartResult(code: String, session: Int32) {
        guard let surface else { return }
        code.withCString { code in
            ghostty_surface_dnd_start_response(surface, session, code, nil)
        }
    }

    func dndSendOfferError(index: Int32, code: String, session: Int32) {
        guard let surface else { return }
        code.withCString { code in
            ghostty_surface_dnd_offer_error(surface, session, index, code, nil)
        }
    }

    func dndSendAbortDrag(code: String, session: Int32) {
        guard let surface else { return }
        code.withCString { code in
            ghostty_surface_dnd_abort_drag(surface, session, code, nil)
        }
    }

    func dndSendAction(operation: Int32, session: Int32) {
        guard let surface else { return }
        ghostty_surface_dnd_action_changed(surface, session, operation)
    }

    func dndSendDropped(session: Int32) {
        guard let surface else { return }
        ghostty_surface_dnd_dropped(surface, session)
    }

    func dndSendFinished(cancelled: Bool, session: Int32) {
        guard let surface else { return }
        ghostty_surface_dnd_finished(surface, session, cancelled)
    }

    func dndSendDataRequest(index: Int32, session: Int32) {
        guard let surface else { return }
        ghostty_surface_dnd_request_data(surface, session, index)
    }
}
