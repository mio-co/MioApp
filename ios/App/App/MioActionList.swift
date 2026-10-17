// MioActionList.swift — 替代 UIAlertController(.actionSheet) 的纵向选项列表（v0.3.4）。
// Mac Catalyst 上 actionSheet 被画成一整行横向按钮（选项多时超出屏幕、选不到，例如「翻译成」15 种语言）；
// 这里统一改成纵向列表：
//   - Mac / iPad：popover，锚定到触发它的按钮 / 单元格（没有锚点时居中、无箭头）
//   - iPhone：页面 sheet（medium / large 两档，可下拉关闭）
// 选中后先关闭列表再执行动作（动作里可以接着弹下一个列表 / 页面）。点外面或「取消」= 不选。

import UIKit

final class MioActionList {
    struct Item {
        let title: String
        let style: UIAlertAction.Style
        let checked: Bool
        let image: UIImage?
        let handler: (() -> Void)?
    }

    var title: String?
    var message: String?
    private(set) var items: [Item] = []

    init(title: String?, message: String? = nil) {
        self.title = title
        self.message = message
    }

    /// style = .cancel 的项不显示成一行（列表自带「取消」/ 点外面关闭），只作为取消回调
    func add(_ title: String, style: UIAlertAction.Style = .default, checked: Bool = false, image: UIImage? = nil, handler: (() -> Void)? = nil) {
        items.append(Item(title: title, style: style, checked: checked, image: image, handler: handler))
    }

    /// 是否用 popover（Mac / iPad）；iPhone 用 sheet
    static var usesPopover: Bool {
        MioWebKitCompat.isMac || UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 弹出列表。anchor 优先级：barItem > sourceView(+sourceRect) > vc.view 中央
    @discardableResult
    func present(from vc: UIViewController, barItem: UIBarButtonItem? = nil, sourceView: UIView? = nil, sourceRect: CGRect? = nil) -> UIViewController {
        let list = MioActionListController(list: self)
        let nav = UINavigationController(rootViewController: list)
        if Self.usesPopover {
            nav.modalPresentationStyle = .popover
            nav.preferredContentSize = list.fittingSize
            if let pop = nav.popoverPresentationController {
                pop.delegate = list
                if let item = barItem {
                    pop.barButtonItem = item
                } else if let v = sourceView, v.window != nil {
                    pop.sourceView = v
                    pop.sourceRect = sourceRect ?? v.bounds
                } else {
                    pop.sourceView = vc.view
                    pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
            }
        } else {
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = list.rowCount > 6 ? [.medium(), .large()] : [.medium()]
                sheet.prefersGrabberVisible = true
            }
        }
        // 当前已经在弹出别的控制器（例如上一个列表还没完全收起）时，从最上层弹
        var host = vc
        while let p = host.presentedViewController, !p.isBeingDismissed { host = p }
        host.present(nav, animated: true)
        return nav
    }
}

final class MioActionListController: UITableViewController, UIPopoverPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private let list: MioActionList
    private let rows: [MioActionList.Item]
    private let cancel: MioActionList.Item?
    private var chose = false

    var rowCount: Int { rows.count }

    init(list: MioActionList) {
        self.list = list
        rows = list.items.filter { $0.style != .cancel }
        cancel = list.items.first { $0.style == .cancel }
        super.init(style: .insetGrouped)
        title = list.title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// popover 尺寸：宽 320，高按行数（最多 560，超出滚动）
    var fittingSize: CGSize {
        let row: CGFloat = MioWebKitCompat.isMac ? 36 : 44
        let msg: CGFloat = (list.message?.isEmpty == false) ? 56 : 16
        return CGSize(width: 320, height: min(560, 56 + msg + CGFloat(rows.count) * row + 24))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        tableView.accessibilityIdentifier = "mio.actionList"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: cancel?.title ?? "取消", style: .plain, target: self, action: #selector(cancelTapped))
        navigationController?.presentationController?.delegate = self
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { nil }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        (list.message?.isEmpty == false) ? list.message : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        var conf = cell.defaultContentConfiguration()
        conf.text = item.title
        conf.image = item.image
        conf.textProperties.color = item.style == .destructive ? .systemRed : .label
        conf.textProperties.numberOfLines = 0
        cell.contentConfiguration = conf
        cell.accessoryType = item.checked ? .checkmark : .none
        cell.accessibilityTraits = item.checked ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        choose(rows[indexPath.row].handler)
    }

    /// 冒烟测试 / 键盘：按标题选中一项
    @discardableResult
    func select(title: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.title == title }) else { return false }
        choose(rows[i].handler)
        return true
    }

    var titles: [String] { rows.map { $0.title } }

    private func choose(_ handler: (() -> Void)?) {
        guard !chose else { return }
        chose = true
        let nav = navigationController ?? self
        nav.dismiss(animated: true) { handler?() }
    }

    @objc private func cancelTapped() {
        guard !chose else { return }
        chose = true
        let h = cancel?.handler
        (navigationController ?? self).dismiss(animated: true) { h?() }
    }

    // Mac / iPad 窄窗口时也保持 popover，不变成全屏
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    // 点外面 / 下拉关闭 = 取消
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !chose else { return }
        chose = true
        cancel?.handler?()
    }
}

/// Mac 冒烟：在内置浏览器里弹出「翻译成」列表，检查是纵向列表（popover）、所有语言都在、整体在窗口内
enum MioActionListSmoke {
    static func run(completion: @escaping ([String: Any], Bool) -> Void) {
        guard let vc = MioTabsViewController.shared?.activeController, vc.view.window != nil else {
            completion(["error": "browser not presented"], false); return
        }
        MioTranslate.presentLanguagePicker(from: vc, sourceItem: nil, sourceView: nil, done: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var r: [String: Any] = [:]
            guard let nav = MioTranslate.lastLanguagePicker as? UINavigationController,
                  let list = nav.viewControllers.first as? MioActionListController,
                  let win = nav.view.window else {
                completion(["error": "picker not shown", "top": String(describing: MioBrowserViewController.topPresenter(vc).map { type(of: $0) })], false)
                return
            }
            let langs = MioTranslateCore.languages.count
            r["rows"] = list.tableView.numberOfRows(inSection: 0)
            r["languages"] = langs
            r["popover"] = nav.modalPresentationStyle == .popover
            let frame = nav.view.convert(nav.view.bounds, to: win)
            r["frame"] = NSCoder.string(for: frame)
            r["window"] = NSCoder.string(for: win.bounds)
            let inside = win.bounds.insetBy(dx: -1, dy: -1).contains(frame)
            r["insideWindow"] = inside
            let c0 = list.tableView.rectForRow(at: IndexPath(row: 0, section: 0))
            let c1 = list.tableView.rectForRow(at: IndexPath(row: min(1, langs - 1), section: 0))
            let vertical = c1.minY > c0.minY && abs(c1.minX - c0.minX) < 1
            r["vertical"] = vertical
            let ok = (r["rows"] as? Int) == langs && vertical && inside && (!MioWebKitCompat.isMac || (r["popover"] as? Bool) == true)
            r["ok"] = ok
            nav.dismiss(animated: false) { completion(r, ok) }
        }
    }
}
