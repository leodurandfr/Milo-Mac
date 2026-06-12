import AppKit

// MARK: - Menu Item Helper
class MenuItemHelper {

    // MARK: - Simple Menu Items
    static func createSimpleMenuItem(title: String, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()

        let containerView = HoverableView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        containerView.configureHoverBackground(leftMargin: 5, rightMargin: 5)

        let textField = NSTextField(labelWithString: title)
        textField.font = NSFont.menuFont(ofSize: 13)
        textField.textColor = NSColor.labelColor
        textField.frame = NSRect(x: 12, y: 8, width: 200, height: 16)
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear

        containerView.addSubview(textField)
        containerView.clickHandler = { [weak target] in
            _ = target?.perform(action)
        }

        item.view = containerView
        return item
    }
}
