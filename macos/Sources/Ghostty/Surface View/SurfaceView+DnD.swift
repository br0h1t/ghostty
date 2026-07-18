import AppKit
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
