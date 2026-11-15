import Foundation

/// Watches a bounded editable package, including nested resources and atomic
/// editor replacements. It does not watch the parent filesystem or log content.
public final class SourceFileWatcher: @unchecked Sendable {
    public let rootURL: URL
    private let interval: TimeInterval
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.localaibasetools.source-watch", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var lastSignature = ""
    private var pending: DispatchWorkItem?
    private var generation: UInt64 = 0

    public init(rootURL: URL, interval: TimeInterval = 0.3, debounce: TimeInterval = 0.25,
                onChange: @escaping @Sendable () -> Void) {
        self.rootURL = rootURL
        self.interval = max(0.02, interval)
        self.debounce = max(0, debounce)
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stop() }

    public func start() {
        onQueue {
            guard timer == nil else { return }
            generation &+= 1
            lastSignature = signature()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }
    public func stop() {
        onQueue {
            generation &+= 1
            pending?.cancel(); pending = nil
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
        }
    }
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() }
        else { queue.sync(execute: body) }
    }
    private func tick() {
        let value = signature()
        guard value != lastSignature else { return }
        lastSignature = value
        pending?.cancel()
        let captured = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.timer != nil, self.generation == captured else { return }
            self.pending = nil
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
    private func signature() -> String {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return "invalid-root" }
            let files = try SourcePackageInspector.sourceFiles(in: root)
            var input = Data()
            var total = 0
            for path in files {
                let url = try SourcePackageRules.containedURL(path, root: root)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                input.append(Data((path + "\0" + String(describing: attributes[.modificationDate]) + "\0" + String(describing: attributes[.size]) + "\0").utf8))
                if let size = attributes[.size] as? NSNumber, size.intValue <= SourcePackageRules.maximumFileBytes,
                   total + size.intValue <= SourcePackageRules.maximumPackageBytes {
                    let data = try SourcePackageRules.boundedData(url)
                    total += data.count
                    input.append(Data(SourcePackageRules.digest(data).utf8))
                }
            }
            return SourcePackageRules.digest(input)
        } catch { return "unreadable-package" }
    }
}
