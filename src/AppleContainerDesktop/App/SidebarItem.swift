import Foundation

enum SidebarItem: String, CaseIterable {
    case system = "Runtime"
    case containers = "Containers"
    case images = "Images"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    case operations = "Operations"
    case settings = "Settings"

    var resourceKind: ResourceKind? {
        switch self {
        case .containers:
            .containers
        case .images:
            .images
        case .networks:
            .networks
        case .volumes:
            .volumes
        case .registries:
            .registry
        case .system, .operations, .settings:
            nil
        }
    }
}
