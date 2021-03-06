import func Cinotify.inotify_init1
import func Cinotify.inotify_rm_watch
import struct Dispatch.DispatchQoS
import class Dispatch.DispatchQueue
import class Dispatch.DispatchWorkItem
import func Glibc.close
import func Glibc.read
import struct Pathman.GenericPath
import protocol Pathman.Path

public final class Inotify {
    public let fileDescriptor: FileDescriptor
    private var watchers = Set<InotifyWatcher>()
    private var buffer = ReadableRingBuffer(size: InotifyEvent.maxSize)
    private var _work: DispatchWorkItem?
    public var isRunning: Bool { return _work != nil }
    private var movedFromCookies = Set<InotifyCookie>()

    public init(flags: [InotifyInitFlag]) throws {
        fileDescriptor = inotify_init1(flags.rawValue)

        guard fileDescriptor != -1 else {
            throw InotifyError.InitError()
        }
    }

    public convenience init(flags: InotifyInitFlag...) throws {
        try self.init(flags: flags)
    }

    @discardableResult
    public func watch<PathType: Path,
                      DelegateType: InotifyEventDelegate>
    (path: PathType,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegates: [DelegateType]) throws -> InotifyWatcherID {
        var watcher: InotifyWatcher
        let genericPath = GenericPath(path)

        if let index = watchers.firstIndex(where: { $0.path == genericPath }) {
            watcher = watchers[index]
            watchers.remove(watcher)

            if masks.contains(.add) {
                try watcher.combine(in: fileDescriptor, events: events, masks: masks, delegates: delegates)
            } else {
                try watcher.overwrite(in: fileDescriptor, events: events, masks: masks, delegates: delegates)
            }
        } else {
            watcher = try InotifyWatcher(path: path, events: events, masks: masks, fd: fileDescriptor, delegates: delegates)
        }

        watchers.insert(watcher)

        return watcher.id
    }

    @discardableResult
    public func watch<PathType: Path,
                      DelegateType: InotifyEventDelegate>
    (path: PathType,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegate: DelegateType) throws -> InotifyWatcherID {
        return try watch(path: path, for: events, with: masks, notify: [delegate])
    }

    @discardableResult
    public func watch<DelegateType: InotifyEventDelegate>
    (path: String,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegates: [DelegateType]) throws -> InotifyWatcherID {
        return try watch(path: GenericPath(path), for: events, with: masks, notify: delegates)
    }

    @discardableResult
    public func watch<DelegateType: InotifyEventDelegate>
    (path: String,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegate: DelegateType) throws -> InotifyWatcherID {
        return try watch(path: path, for: events, with: masks, notify: [delegate])
    }

    public func watch<DelegateType: InotifyEventDelegate>
    (watcherID: InotifyWatcherID,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegates: [DelegateType]) throws {
        guard let index = watchers.firstIndex(where: { $0.id == watcherID }) else {
            throw InotifyError.UnwatchError.noWatcherWithIdentifier(watcherID)
        }

        var watcher = watchers[index]
        watchers.remove(watcher)

        if masks.contains(.add) {
            try watcher.combine(in: fileDescriptor, events: events, masks: masks, delegates: delegates)
        } else {
            try watcher.overwrite(in: fileDescriptor, events: events, masks: masks, delegates: delegates)
        }

        watchers.insert(watcher)
    }

    public func watch<DelegateType: InotifyEventDelegate>
    (watcherID: InotifyWatcherID,
     for events: [FileSystemEvent],
     with masks: [AddWatchMask] = [],
     notify delegate: DelegateType) throws {
        try self.watch(watcherID: watcherID, for: events, with: masks, notify: [delegate])
    }

    public func unwatch<PathType: Path>(path: PathType) throws {
        guard let index = watchers.firstIndex(where: { $0.path == GenericPath(path) }) else {
            throw InotifyError.UnwatchError.noWatcherWithPath(path.string)
        }
        try watchers.remove(at: index).unwatch(fd: fileDescriptor)
    }

    public func unwatch(path: String) throws {
        guard let index = watchers.firstIndex(where: { $0.path == GenericPath(path) }) else {
            throw InotifyError.UnwatchError.noWatcherWithPath(path)
        }
        try watchers.remove(at: index).unwatch(fd: fileDescriptor)
    }

    public func unwatch(watcherID: InotifyWatcherID) throws {
        guard let index = watchers.firstIndex(where: { $0.id == watcherID }) else {
            throw InotifyError.UnwatchError.noWatcherWithIdentifier(watcherID)
        }
        try watchers.remove(at: index).unwatch(fd: fileDescriptor)
    }

    private func unwatch(watcher: InotifyWatcher) throws {
        guard let _watcher = watchers.remove(watcher) else {
            throw InotifyError.UnwatchError.noWatcher(watcher)
        }
        try _watcher.unwatch(fd: fileDescriptor)
    }

    public func start(on queue: DispatchQueue, using poller: EventPoller.Type = SelectPoller.self) {
        guard _work == nil else { return }

        _work = DispatchWorkItem(qos: .utility) {
            while true {
                try? self.wait(using: poller)
            }
        }

        queue.async(execute: _work!)
    }

    public func start(qos: DispatchQoS = .utility, using poller: EventPoller.Type = SelectPoller.self) {
        start(on: .global(qos: qos.qosClass), using: poller)
    }

    public func stop() {
        guard let work = _work else { return }
        defer { _work = nil }
        work.cancel()
    }

    public func wait(using poller: EventPoller.Type = SelectPoller.self) throws {
        try poller.wait(forEventsIn: self)

        for event in try readEvents() {
            // Skip ignored events
            guard !event.masks.contains(.ignored) else { continue }

            guard let watcher = watchers.first(where: { $0.watchDescriptor == event.wd }) else {
                throw InotifyError.LocateWatcherError.noWatcherWithDescriptor(event.wd)
            }

            if watcher.masks.contains(.oneShot) {
                try? unwatch(watcher: watcher)
            }

            // Try to match up movedFrom and movedTo pairs (generated by renaming files) and don't trigger the watcher
            // for the movedTo event (to make sure that a single rename(2) only triggers the action once)

            // The cookie will be non-zero only when a rename(2) occurs
            if event.events.contains(DirectoryEvent.movedFrom), event.cookie != 0 {
                movedFromCookies.insert(event.cookie)
            }

            // If we match a movedFrom with a subsequent movedTo event, then we can remove it from our stored cache of
            // movedFrom cookies and skip the event trigger
            guard !(event.events.contains(DirectoryEvent.movedTo) && movedFromCookies.contains(event.cookie)) else {
                movedFromCookies.remove(event.cookie)
                continue
            }

            watcher.trigger(with: event)
        }
    }

    private func readEvents() throws -> [InotifyEvent] {
        var events: [InotifyEvent] = []
        var bytesRead: Int
        repeat {
            bytesRead = try buffer.read(from: fileDescriptor, bytes: InotifyEvent.maxSize)
            while let event = buffer.pullEvent() {
                events.append(event)
            }
        } while bytesRead > 0 && bytesRead == InotifyEvent.maxSize

        return events
    }

    deinit {
        stop()
        close(fileDescriptor)
    }
}

private extension DispatchQoS {
    var qosClass: DispatchQoS.QoSClass {
        switch self {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .default: return .default
        case .utility: return .utility
        case .background: return .background
        default: return .unspecified
        }
    }
}
