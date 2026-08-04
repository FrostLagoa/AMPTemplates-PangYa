param(
    [Parameter(Mandatory = $true)]
    [string]$ListenAddress,
    [Parameter(Mandatory = $true)]
    [string]$RoutesBase64
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$source = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

public sealed class PangyaTcpRelay : IDisposable
{
    private readonly TcpListener listener;
    private readonly IPAddress targetAddress;
    private readonly int targetPort;
    private readonly CancellationTokenSource cancellation = new CancellationTokenSource();

    public PangyaTcpRelay(IPAddress listenAddress, int listenPort, IPAddress targetAddress, int targetPort)
    {
        this.listener = new TcpListener(listenAddress, listenPort);
        this.targetAddress = targetAddress;
        this.targetPort = targetPort;
    }

    public void Start()
    {
        this.listener.Start();
        this.AcceptLoop();
    }

    private async void AcceptLoop()
    {
        while (!this.cancellation.IsCancellationRequested)
        {
            TcpClient incoming = null;
            try
            {
                incoming = await this.listener.AcceptTcpClientAsync().ConfigureAwait(false);
                RelayConnection(incoming);
            }
            catch (ObjectDisposedException)
            {
                if (this.cancellation.IsCancellationRequested)
                {
                    return;
                }
                throw;
            }
            catch (SocketException)
            {
                if (this.cancellation.IsCancellationRequested)
                {
                    return;
                }
                throw;
            }
            catch
            {
                if (incoming != null)
                {
                    incoming.Dispose();
                }
                if (!this.cancellation.IsCancellationRequested)
                {
                    Thread.Sleep(250);
                }
            }
        }
    }

    private async void RelayConnection(TcpClient incoming)
    {
        using (incoming)
        using (var outgoing = new TcpClient(AddressFamily.InterNetwork))
        {
            try
            {
                await outgoing.ConnectAsync(this.targetAddress, this.targetPort).ConfigureAwait(false);
                using (NetworkStream incomingStream = incoming.GetStream())
                using (NetworkStream outgoingStream = outgoing.GetStream())
                {
                    Task inbound = Pump(incomingStream, outgoingStream, this.cancellation.Token);
                    Task outbound = Pump(outgoingStream, incomingStream, this.cancellation.Token);
                    await Task.WhenAny(inbound, outbound).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            catch (IOException)
            {
            }
            catch (SocketException)
            {
            }
        }
    }

    private static async Task Pump(Stream source, Stream destination, CancellationToken cancellationToken)
    {
        var buffer = new byte[65536];
        while (!cancellationToken.IsCancellationRequested)
        {
            int read = await source.ReadAsync(buffer, 0, buffer.Length, cancellationToken).ConfigureAwait(false);
            if (read <= 0)
            {
                return;
            }
            await destination.WriteAsync(buffer, 0, read, cancellationToken).ConfigureAwait(false);
        }
    }

    public void Dispose()
    {
        if (this.cancellation.IsCancellationRequested)
        {
            return;
        }
        this.cancellation.Cancel();
        this.listener.Stop();
        this.cancellation.Dispose();
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

$listenIp = [Net.IPAddress]::Parse($ListenAddress)
if ($listenIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "The PangYa relay listen address must be IPv4."
}
$routesJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RoutesBase64))
$decodedRoutes = ConvertFrom-Json -InputObject $routesJson
$routes = New-Object System.Collections.Generic.List[object]
if ($decodedRoutes -is [Array]) {
    foreach ($decodedRoute in $decodedRoutes) {
        if ($null -ne $decodedRoute) { $routes.Add($decodedRoute) }
    }
}
elseif ($null -ne $decodedRoutes) {
    $routes.Add($decodedRoutes)
}
if ($routes.Count -lt 1 -or $routes.Count -gt 8) {
    throw "The PangYa relay route count is invalid."
}

$relays = New-Object System.Collections.Generic.List[object]
try {
    foreach ($route in $routes) {
        $listenPort = [int]$route.listen_port
        $targetPort = [int]$route.target_port
        $targetIp = [Net.IPAddress]::Parse([string]$route.target_address)
        if ($listenPort -lt 1 -or $listenPort -gt 65535 -or $targetPort -lt 1 -or $targetPort -gt 65535) {
            throw "A PangYa relay port is invalid."
        }
        if ($targetIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw "A PangYa relay target must be IPv4."
        }
        $relay = [PangyaTcpRelay]::new($listenIp, $listenPort, $targetIp, $targetPort)
        $relay.Start()
        $relays.Add($relay)
    }
    [Console]::WriteLine(("[relay] READY listen={0} routes={1}" -f $ListenAddress, $routes.Count))
    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line -or $line.Trim().Equals("exit", [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
    }
}
finally {
    foreach ($relay in $relays) {
        $relay.Dispose()
    }
    [Console]::WriteLine("[relay] STOPPED")
}
