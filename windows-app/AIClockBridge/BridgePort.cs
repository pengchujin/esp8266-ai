namespace AIClockBridge;

// Port of the Swift BridgePort. The local HTTP port the clock polls: 8765 by
// default, but that port collides with other software on some machines
// (issue #18: 百度输入法's baidupinyin.exe listens on 0.0.0.0:8765 and can't be
// told not to, and its service restarts it if killed), so it is overridable.
// The firmware needs no change — its "Bridge host" field has always been
// host:port.
static class BridgePort
{
    public const int Fallback = 8765;
    const string Key = "bridge_port";

    /// <summary>
    /// --port N &gt; AICLOCK_PORT &gt; saved setting &gt; 8765. The flag is for
    /// one-off runs / shortcuts, the env var for scripted starts, the saved
    /// setting for the tray menu item.
    /// </summary>
    public static int Resolve(string[] args)
    {
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--port" && Parse(args[i + 1]) is int fromArg) return fromArg;
        }
        if (Parse(Environment.GetEnvironmentVariable("AICLOCK_PORT")) is int fromEnv) return fromEnv;
        if (Parse(Saved) is int fromSettings) return fromSettings;
        return Fallback;
    }

    /// <summary>Empty string = no override. Takes effect on the next launch.</summary>
    public static string Saved
    {
        get => Settings.Get(Key);
        set => Settings.Set(Key, value);
    }

    public static int? Parse(string text)
    {
        if (int.TryParse((text ?? "").Trim(), out var n) && n >= 1 && n <= 65535) return n;
        return null;
    }
}
