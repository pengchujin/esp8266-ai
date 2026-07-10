using System.Drawing;
using SixLabors.ImageSharp.PixelFormats;

namespace AIClockBridge;

// "更换桌宠动画" window: browse petdex.dev's gallery, preview an animation
// row, and push it to the clock as the Claude, Codex or Kimi character.
// Singleton so the tray menu can open it repeatedly.
sealed class PetPickerForm : Form
{
    static PetPickerForm _shared;

    public static void ShowShared()
    {
        if (_shared == null || _shared.IsDisposed) _shared = new PetPickerForm();
        _shared.Show();
        _shared.WindowState = FormWindowState.Normal;
        _shared.Activate();
        if (_shared._allPets.Count == 0) _ = _shared.LoadManifest();
    }

    readonly TextBox _searchBox = new();
    readonly ListBox _listBox = new();
    readonly ComboBox _targetCombo = new();
    readonly ComboBox _stateCombo = new();
    readonly PictureBox _preview = new();
    readonly Button _uploadButton = new();
    readonly Label _statusLabel = new();

    List<PetdexPet> _allPets = new();
    List<PetdexPet> _filtered = new();
    (string Slug, SixLabors.ImageSharp.Image<Rgba32> Image)? _sheetCache;
    int _previewToken;

    PetPickerForm()
    {
        Text = "更换桌宠动画（petdex.dev）";
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 9f);
        ClientSize = new Size(Px(480), Px(620));
        MinimumSize = new Size(Px(420), Px(520));

        _searchBox.PlaceholderText = "搜索 3300+ 桌宠（如 pikachu、boba…）";
        _searchBox.TextChanged += (_, _) => ApplyFilter();

        _listBox.IntegralHeight = false;
        _listBox.SelectedIndexChanged += (_, _) => PreviewSelectionChanged();

        _targetCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _targetCombo.Items.AddRange(new object[] { "Claude 角色", "Codex 角色", "Kimi 角色" });
        _targetCombo.SelectedIndex = 0;
        _targetCombo.SelectedIndexChanged += (_, _) => PreviewSelectionChanged();

        _stateCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        foreach (var s in PetdexService.States) _stateCombo.Items.Add(s.Label);
        _stateCombo.SelectedIndex = Array.FindIndex(PetdexService.States, s => s.Id == "running");
        _stateCombo.SelectedIndexChanged += (_, _) => PreviewSelectionChanged();

        _preview.BackColor = Color.Black;
        _preview.SizeMode = PictureBoxSizeMode.Zoom; // PictureBox animates GIFs natively

        _uploadButton.Text = "上传到设备";
        _uploadButton.Enabled = false;
        _uploadButton.Click += async (_, _) => await UploadTapped();
        AcceptButton = _uploadButton;

        _statusLabel.ForeColor = SystemColors.GrayText;
        _statusLabel.AutoEllipsis = true;

        Controls.AddRange(new Control[]
        {
            _searchBox, _listBox, _preview, _targetCombo, _stateCombo, _uploadButton, _statusLabel,
        });
        Layout += (_, _) => DoLayout();
        DoLayout();
    }

    int Px(int logical) => (int)Math.Round(logical * DeviceDpi / 96f);

    void DoLayout()
    {
        var pad = Px(14);
        var w = ClientSize.Width - 2 * pad;
        var y = pad;
        _searchBox.SetBounds(pad, y, w, Px(26));
        y += Px(34);
        var listHeight = ClientSize.Height - y - Px(14 + 140 + 10 + 30 + 10 + 22 + 10);
        _listBox.SetBounds(pad, y, w, Math.Max(Px(160), listHeight));
        y += _listBox.Height + Px(10);
        _preview.SetBounds(pad, y, Px(140), Px(140));
        y += Px(150);
        _targetCombo.SetBounds(pad, y, Px(140), Px(26));
        _stateCombo.SetBounds(pad + Px(150), y, Px(170), Px(26));
        _uploadButton.SetBounds(pad + Px(330), y, w - Px(330), Px(28));
        y += Px(38);
        _statusLabel.SetBounds(pad, y, w, Px(22));
    }

    async Task LoadManifest()
    {
        _statusLabel.Text = "正在加载 petdex 桌宠列表…";
        try
        {
            var pets = await PetdexService.LoadManifest();
            _allPets = pets.OrderBy(p => p.DisplayName, StringComparer.OrdinalIgnoreCase).ToList();
            ApplyFilter();
            _statusLabel.Text = $"共 {pets.Count} 个桌宠，选择后可预览";
        }
        catch (Exception e)
        {
            _statusLabel.Text = $"加载失败：{e.Message}";
        }
    }

    void ApplyFilter()
    {
        var q = _searchBox.Text.Trim().ToLowerInvariant();
        _filtered = q.Length == 0 ? _allPets : _allPets.Where(p =>
            p.Slug.ToLowerInvariant().Contains(q)
            || p.DisplayName.ToLowerInvariant().Contains(q)).ToList();
        _listBox.BeginUpdate();
        _listBox.Items.Clear();
        foreach (var pet in _filtered)
        {
            _listBox.Items.Add(pet.Kind.Length == 0
                ? $"{pet.DisplayName}（{pet.Slug}）"
                : $"{pet.DisplayName}（{pet.Slug} · {pet.Kind}）");
        }
        _listBox.EndUpdate();
    }

    // MARK: - preview / upload

    PetdexPet SelectedPet
    {
        get
        {
            var row = _listBox.SelectedIndex;
            return row >= 0 && row < _filtered.Count ? _filtered[row] : null;
        }
    }

    PetdexAnimState SelectedState =>
        PetdexService.States[Math.Max(0, _stateCombo.SelectedIndex)];

    /// Device slot pixel sizes must match the firmware's sprite constants.
    (string Slot, int W, int H) SlotSize => _targetCombo.SelectedIndex switch
    {
        0 => ("claude", 111, 120),
        2 => ("kimi", 120, 120),
        _ => ("codex", 120, 120),
    };

    async void PreviewSelectionChanged()
    {
        var pet = SelectedPet;
        if (pet == null) return;
        _uploadButton.Enabled = false;
        var token = ++_previewToken;

        SixLabors.ImageSharp.Image<Rgba32> sheet;
        if (_sheetCache?.Slug == pet.Slug)
        {
            sheet = _sheetCache.Value.Image;
        }
        else
        {
            _statusLabel.Text = $"正在下载 {pet.DisplayName} 的动画…";
            try
            {
                sheet = await PetdexService.DownloadSpritesheet(pet);
            }
            catch (Exception e)
            {
                if (_previewToken == token) _statusLabel.Text = $"下载失败：{e.Message}";
                return;
            }
            if (_previewToken != token)
            {
                sheet.Dispose();
                return;
            }
            if (_sheetCache?.Slug != pet.Slug) _sheetCache?.Image?.Dispose();
            _sheetCache = (pet.Slug, sheet);
        }

        var s = SlotSize;
        var state = SelectedState;
        var gif = await Task.Run(() => PetdexService.BuildGif(sheet, state, s.W, s.H));
        if (_previewToken != token) return;
        if (gif != null)
        {
            var old = _preview.Image;
            _preview.Image = System.Drawing.Image.FromStream(new MemoryStream(gif));
            old?.Dispose();
            _uploadButton.Enabled = true;
            _statusLabel.Text = $"{pet.DisplayName} · {state.Label} → {s.Slot}";
        }
        else
        {
            _statusLabel.Text = "GIF 生成失败";
        }
    }

    async Task UploadTapped()
    {
        var pet = SelectedPet;
        if (_sheetCache == null || pet == null || _sheetCache.Value.Slug != pet.Slug) return;
        var s = SlotSize;
        var state = SelectedState;
        var sheet = _sheetCache.Value.Image;
        var gif = await Task.Run(() => PetdexService.BuildGif(sheet, state, s.W, s.H));
        if (gif == null)
        {
            _statusLabel.Text = "GIF 生成失败";
            return;
        }
        _uploadButton.Enabled = false;
        _statusLabel.Text = "正在上传到设备并解码（约几秒）…";
        try
        {
            await DeviceClient.UploadGif(gif, s.Slot);
            var slotName = s.Slot == "claude" ? "Claude" : s.Slot == "kimi" ? "Kimi" : "Codex";
            _statusLabel.Text = $"✅ 已应用：{pet.DisplayName} 现在是 {slotName} 的桌宠";
        }
        catch (Exception e)
        {
            _statusLabel.Text = $"上传失败：{e.Message}";
        }
        finally
        {
            _uploadButton.Enabled = true;
        }
    }
}
