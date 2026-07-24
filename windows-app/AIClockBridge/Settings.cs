using System.Text.Json;

namespace AIClockBridge;

// UserDefaults stand-in: a tiny JSON key/value store under %APPDATA%.
// Holds device addressing plus the stable ID of the selected network adapter.
static class Settings
{
    static readonly object Lock = new();
    static readonly string Path = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "AIClockBridge", "settings.json");
    static Dictionary<string, string> _values;

    static Dictionary<string, string> Values
    {
        get
        {
            if (_values == null)
            {
                try
                {
                    _values = JsonSerializer.Deserialize<Dictionary<string, string>>(
                        File.ReadAllText(Path)) ?? new();
                }
                catch
                {
                    _values = new();
                }
            }
            return _values;
        }
    }

    public static string Get(string key)
    {
        lock (Lock) return Values.TryGetValue(key, out var v) ? v : "";
    }

    public static void Set(string key, string value)
    {
        lock (Lock)
        {
            Values[key] = value;
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
                File.WriteAllText(Path, JsonSerializer.Serialize(Values,
                    new JsonSerializerOptions { WriteIndented = true }));
            }
            catch
            {
                // best effort; in-memory value still applies for this session
            }
        }
    }
}
