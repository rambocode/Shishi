import Foundation
import ShishiCore

@MainActor
enum RoutePreferences {
    static func restore(store: TaskStore) -> Route {
        guard let value = UserDefaults.standard.string(forKey: "lastRoute") else { return .today }
        switch value {
        case "inbox": return .inbox
        case "today": return .today
        case "upcoming": return .upcoming
        case "anytime": return .anytime
        case "someday": return .someday
        case "logbook": return .logbook
        case "trash": return .trash
        default:
            let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return .today }
            if pieces[0] == "tag", store.allTags.contains(pieces[1]) { return .tag(pieces[1]) }
            guard let id = UUID(uuidString: pieces[1]) else { return .today }
            if pieces[0] == "project", store.projects.contains(where: { $0.id == id }) { return .project(id) }
            if pieces[0] == "area", store.areas.contains(where: { $0.id == id }) { return .area(id) }
            return .today
        }
    }
    static func save(_ route: Route) {
        let value: String
        switch route {
        case .inbox: value = "inbox"
        case .today: value = "today"
        case .upcoming: value = "upcoming"
        case .anytime: value = "anytime"
        case .someday: value = "someday"
        case .logbook: value = "logbook"
        case .trash: value = "trash"
        case .project(let id): value = "project:" + id.uuidString
        case .area(let id): value = "area:" + id.uuidString
        case .tag(let tag): value = "tag:" + tag
        case .search: return
        }
        UserDefaults.standard.set(value, forKey: "lastRoute")
    }
}
