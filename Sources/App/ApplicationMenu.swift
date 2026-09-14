import Cocoa

func makeApplicationMenu() -> NSMenu {
    let menu = NSMenu()

    let applicationMenu = NSMenu(title: "PasteHistory")
    applicationMenu.addItem(withTitle: "退出 PasteHistory", action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "q")
    let applicationItem = NSMenuItem()
    applicationItem.submenu = applicationMenu
    menu.addItem(applicationItem)

    // Accessory apps still need a main Edit menu for AppKit to route standard
    // keyboard equivalents to the focused text view or text field editor.
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = editMenu
    menu.addItem(editItem)
    return menu
}
