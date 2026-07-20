using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace AIClockBridge;

// Central source of truth for the LAN adapter used by the bridge. The stable
// NetworkInterface.Id is persisted; the IPv4 address is resolved again on each
// use so DHCP address changes do not invalidate the setting.
sealed class NetworkAdapterInfo
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";
    public IPAddress Address { get; init; }
    public int PrefixLength { get; init; } = 24;
    public bool HasGateway { get; init; }
    public NetworkInterface Interface { get; init; }
}

static class NetworkBinding
{
    const string InterfaceKey = "network_interface_id";
    static readonly object ChangeLock = new();
    static readonly System.Threading.Timer AddressChangeTimer = new(
        _ => RaiseChanged(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);

    public static event Action Changed;

    static NetworkBinding()
    {
        // Adapter address changes often arrive in bursts. Re-resolve the saved
        // adapter after the burst so the listener and counters follow DHCP.
        NetworkChange.NetworkAddressChanged += (_, _) =>
        {
            lock (ChangeLock)
            {
                AddressChangeTimer.Change(TimeSpan.FromMilliseconds(750), Timeout.InfiniteTimeSpan);
            }
        };
    }

    /// Empty means automatic selection. A non-empty ID never silently falls
    /// back to another adapter if the saved adapter is missing or disconnected.
    public static string SelectedInterfaceId
    {
        get => Settings.Get(InterfaceKey);
        set
        {
            var normalized = value?.Trim() ?? "";
            if (string.Equals(Settings.Get(InterfaceKey), normalized,
                              StringComparison.OrdinalIgnoreCase)) return;
            Settings.Set(InterfaceKey, normalized);
            RaiseChanged();
        }
    }

    public static IReadOnlyList<NetworkAdapterInfo> AvailableAdapters()
    {
        var result = new List<NetworkAdapterInfo>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                IPInterfaceProperties properties;
                try { properties = nic.GetIPProperties(); }
                catch { continue; }

                var address = properties.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                    .Where(a => !IPAddress.IsLoopback(a.Address))
                    .OrderBy(a => IsLinkLocal(a.Address) ? 1 : 0)
                    .FirstOrDefault();
                if (address == null) continue;

                var hasGateway = properties.GatewayAddresses.Any(g =>
                    g.Address?.AddressFamily == AddressFamily.InterNetwork
                    && !g.Address.Equals(IPAddress.Any));
                result.Add(new NetworkAdapterInfo
                {
                    Id = nic.Id,
                    Name = nic.Name,
                    Description = nic.Description,
                    Address = address.Address,
                    PrefixLength = address.PrefixLength,
                    HasGateway = hasGateway,
                    Interface = nic,
                });
            }
        }
        catch
        {
            // Return what was collected before a transient enumeration error.
        }

        return result
            .OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(a => a.Address.ToString(), StringComparer.Ordinal)
            .ToArray();
    }

    public static NetworkAdapterInfo EffectiveAdapter()
    {
        var adapters = AvailableAdapters();
        var selectedId = SelectedInterfaceId;
        if (selectedId.Length > 0)
        {
            return adapters.FirstOrDefault(a => string.Equals(
                a.Id, selectedId, StringComparison.OrdinalIgnoreCase));
        }

        return adapters
            .OrderByDescending(a => a.HasGateway)
            .ThenByDescending(a => IsPhysical(a.Interface.NetworkInterfaceType))
            .ThenBy(a => LooksVirtual(a.Description))
            .ThenBy(a => IsLinkLocal(a.Address))
            .FirstOrDefault();
    }

    public static IPAddress LocalIPv4Address() => EffectiveAdapter()?.Address;

    /// Addresses to probe on the selected adapter's subnet. Large enterprise
    /// subnets are limited to the local /24 slice so one menu click cannot
    /// launch tens of thousands of HTTP requests.
    public static IReadOnlyList<string> ScanAddresses()
    {
        var adapter = EffectiveAdapter();
        if (adapter == null) return Array.Empty<string>();

        var bytes = adapter.Address.GetAddressBytes();
        if (bytes.Length != 4) return Array.Empty<string>();
        var ip = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16)
            | ((uint)bytes[2] << 8) | bytes[3];
        var prefix = Math.Clamp(Math.Max(adapter.PrefixLength, 24), 0, 32);
        var mask = prefix == 0 ? 0u : uint.MaxValue << (32 - prefix);
        var network = ip & mask;
        var broadcast = network | ~mask;
        if (broadcast <= network + 1) return Array.Empty<string>();

        var result = new List<string>((int)(broadcast - network - 1));
        for (var candidate = network + 1; candidate < broadcast; candidate++)
        {
            if (candidate == ip) continue;
            result.Add(new IPAddress(new[]
            {
                (byte)(candidate >> 24), (byte)(candidate >> 16),
                (byte)(candidate >> 8), (byte)candidate,
            }).ToString());
        }
        return result;
    }

    public static string UnavailableMessage => SelectedInterfaceId.Length == 0
        ? "没有可用的 IPv4 网卡"
        : "选中的网卡不可用，请在托盘菜单的“绑定网卡”中重新选择";

    static bool IsPhysical(NetworkInterfaceType type) =>
        type == NetworkInterfaceType.Ethernet || type == NetworkInterfaceType.Wireless80211;

    static bool LooksVirtual(string description)
    {
        var value = description?.ToLowerInvariant() ?? "";
        return value.Contains("virtual") || value.Contains("vpn") || value.Contains("tap")
            || value.Contains("hyper-v") || value.Contains("vmware")
            || value.Contains("loopback") || value.Contains("wintun");
    }

    static bool IsLinkLocal(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 && bytes[0] == 169 && bytes[1] == 254;
    }

    static void RaiseChanged()
    {
        var handlers = Changed?.GetInvocationList() ?? Array.Empty<Delegate>();
        foreach (var callback in handlers)
        {
            try { ((Action)callback)(); }
            catch (Exception e) { Console.Error.WriteLine($"[network] apply failed: {e.Message}"); }
        }
    }
}
