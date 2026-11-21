import Foundation

/// Product identity in one place, so a rename never means a grep through views.
enum Brand {
  /// Display name. Change here plus `build-app.sh`'s Info.plist.
  static let name = "Cadence"
  static let chineseName = "韵律"
  static let version = "1.0.0"
  static let tagline = "把喜欢的音乐放在一起"
}

extension Platform {
  /// Metaphorical display names: the app never prints the upstream brand, users
  /// already know which colour means which library.
  var displayName: String {
    switch self {
    case .kg: return "鲸"
    case .wy: return "焰"
    case .kw: return "珀"
    case .tx: return "萤"
    }
  }

  /// Longer form for menus and tooltips.
  var subtitle: String {
    switch self {
    case .kg: return "鲸 · 深库"
    case .wy: return "焰 · 热榜"
    case .kw: return "珀 · 琥珀"
    case .tx: return "萤 · 微光"
    }
  }
}
