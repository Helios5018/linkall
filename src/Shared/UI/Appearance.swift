import AppKit
import SwiftUI

/// Shared by the shell and the input method's AppKit settings host.
public enum LinkAppearance {
    public static let sidebarWidth: CGFloat = 216
    public static let pageInset: CGFloat = 28
    public static let titleSize: CGFloat = 24
    public static let cornerRadius: CGFloat = 10
    public static let accent = Color.accentColor
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let titleFont = Font.system(size: titleSize, weight: .semibold, design: .rounded)
    public static var appKitTitleFont: NSFont {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: titleSize) } ?? font
    }
}

public struct LinkSidebarItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let brand: LinkBrand?
    public init(id: String, title: String, subtitle: String, symbol: String, brand: LinkBrand? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.brand = brand
    }
}

public struct LinkSidebar: View {
    let title: String
    let subtitle: String
    let footer: String
    let items: [LinkSidebarItem]
    let selected: String
    let select: (String) -> Void
    public init(title: String, subtitle: String, footer: String, items: [LinkSidebarItem], selected: String, select: @escaping (String) -> Void) {
        self.title = title; self.subtitle = subtitle; self.footer = footer
        self.items = items; self.selected = selected; self.select = select
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let brand = LinkBrand(rawValue: title) {
                        Image(nsImage: brand.image(size: 32, tile: true)).frame(width: 32, height: 32)
                    }
                    Text(title).font(LinkAppearance.titleFont)
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 20)
            ForEach(items) { item in
                Button { select(item.id) } label: {
                    HStack(spacing: 10) {
                        Group {
                            if let brand = item.brand {
                                Image(nsImage: brand.image(size: 24, tile: true)).renderingMode(.original)
                            } else { Image(systemName: item.symbol).font(.system(size: 16, weight: .medium)) }
                        }
                            .foregroundStyle(selected == item.id ? LinkAppearance.accent : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 14, weight: .semibold))
                            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == item.id ? LinkAppearance.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: LinkAppearance.cornerRadius))
                        .contentShape(RoundedRectangle(cornerRadius: LinkAppearance.cornerRadius))
                }.buttonStyle(.plain).accessibilityLabel(item.title)
                    .accessibilityAddTraits(selected == item.id ? [.isSelected] : [])
            }
            Spacer(minLength: 20)
            Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
        }.padding(.horizontal, 12).padding(.vertical, 24)
            .frame(width: LinkAppearance.sidebarWidth).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}
