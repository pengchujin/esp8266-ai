import AppKit

// "更换桌宠动画" window: browse petdex.dev's gallery, preview an animation
// row, and push it to the clock as the Claude or Codex character. All AppKit,
// one class, retained as a singleton so the menu can open it repeatedly.
final class PetPickerWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    static let shared = PetPickerWindowController()

    private var window: NSWindow?
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let targetPopup = NSPopUpButton()
    private let statePopup = NSPopUpButton()
    private let previewView = NSImageView()
    private let uploadButton = NSButton(title: "上传到设备", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var allPets: [PetdexPet] = []
    private var filtered: [PetdexPet] = []
    private var sheetCache: (slug: String, image: CGImage)?
    private var previewToken = 0

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if allPets.isEmpty { loadManifest() }
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "更换桌宠动画（petdex.dev）"
        win.isReleasedWhenClosed = false
        win.center()

        let content = NSView()
        win.contentView = content

        searchField.placeholderString = "搜索 3300+ 桌宠（如 pikachu、boba…）"
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pet"))
        column.title = "桌宠"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true

        targetPopup.addItems(withTitles: ["Claude 角色", "Codex 角色", "Kimi 角色"])
        statePopup.addItems(withTitles: PetdexService.states.map { $0.label })
        statePopup.selectItem(at: PetdexService.states.firstIndex { $0.id == "running" } ?? 0)
        targetPopup.target = self
        targetPopup.action = #selector(previewSelectionChanged)
        statePopup.target = self
        statePopup.action = #selector(previewSelectionChanged)

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.animates = true
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 8

        uploadButton.target = self
        uploadButton.action = #selector(uploadTapped)
        uploadButton.keyEquivalent = "\r"
        uploadButton.isEnabled = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let controls = NSStackView(views: [targetPopup, statePopup, uploadButton])
        controls.orientation = .horizontal
        controls.distribution = .fillProportionally

        let stack = NSStackView(views: [searchField, scroll, previewView, controls, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            previewView.widthAnchor.constraint(equalToConstant: 140),
            previewView.heightAnchor.constraint(equalToConstant: 140),
            controls.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: searchField.widthAnchor),
        ])

        window = win
    }

    private func loadManifest() {
        statusLabel.stringValue = "正在加载 petdex 桌宠列表…"
        PetdexService.loadManifest { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(pets):
                self.allPets = pets.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                self.applyFilter()
                self.statusLabel.stringValue = "共 \(pets.count) 个桌宠，选择后可预览"
            case let .failure(error):
                self.statusLabel.stringValue = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? allPets : allPets.filter {
            $0.slug.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
        tableView.reloadData()
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let text: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            text = reused
        } else {
            text = NSTextField(labelWithString: "")
            text.identifier = id
            text.lineBreakMode = .byTruncatingTail
        }
        let pet = filtered[row]
        text.stringValue = pet.kind.isEmpty ? "\(pet.displayName)（\(pet.slug)）"
            : "\(pet.displayName)（\(pet.slug) · \(pet.kind)）"
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        previewSelectionChanged()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - preview / upload

    private var selectedPet: PetdexPet? {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }

    private var selectedState: PetdexAnimState {
        PetdexService.states[max(0, statePopup.indexOfSelectedItem)]
    }

    /// Device slot pixel sizes must match the firmware's sprite constants.
    private var slotSize: (slot: String, w: Int, h: Int) {
        switch targetPopup.indexOfSelectedItem {
        case 0: return ("claude", 111, 120)
        case 2: return ("kimi", 120, 120)
        default: return ("codex", 120, 120)
        }
    }

    @objc private func previewSelectionChanged() {
        guard let pet = selectedPet else { return }
        uploadButton.isEnabled = false
        previewToken += 1
        let token = previewToken

        let render: (CGImage) -> Void = { [weak self] sheet in
            guard let self = self, self.previewToken == token else { return }
            self.sheetCache = (pet.slug, sheet)
            let s = self.slotSize
            if let gif = PetdexService.buildGif(sheet: sheet, state: self.selectedState,
                                                targetW: s.w, targetH: s.h) {
                self.previewView.image = NSImage(data: gif)
                self.uploadButton.isEnabled = true
                self.statusLabel.stringValue = "\(pet.displayName) · \(self.selectedState.label) → \(s.slot)"
            } else {
                self.statusLabel.stringValue = "GIF 生成失败"
            }
        }

        if let cache = sheetCache, cache.slug == pet.slug {
            render(cache.image)
            return
        }
        statusLabel.stringValue = "正在下载 \(pet.displayName) 的动画…"
        PetdexService.downloadSpritesheet(pet) { [weak self] result in
            guard let self = self, self.previewToken == token else { return }
            switch result {
            case let .success(sheet): render(sheet)
            case let .failure(error): self.statusLabel.stringValue = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func uploadTapped() {
        guard let cache = sheetCache, let pet = selectedPet, cache.slug == pet.slug else { return }
        let s = slotSize
        guard let gif = PetdexService.buildGif(sheet: cache.image, state: selectedState,
                                               targetW: s.w, targetH: s.h) else {
            statusLabel.stringValue = "GIF 生成失败"
            return
        }
        uploadButton.isEnabled = false
        statusLabel.stringValue = "正在上传到设备并解码（约几秒）…"
        DeviceClient.uploadGif(gif, slot: s.slot) { [weak self] error in
            guard let self = self else { return }
            self.uploadButton.isEnabled = true
            let slotName = s.slot == "claude" ? "Claude" : s.slot == "kimi" ? "Kimi" : "Codex"
            self.statusLabel.stringValue = error.map { "上传失败：\($0.localizedDescription)" }
                ?? "✅ 已应用：\(pet.displayName) 现在是 \(slotName) 的桌宠"
        }
    }
}
