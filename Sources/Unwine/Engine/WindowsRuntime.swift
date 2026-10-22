import Foundation

/// One Microsoft runtime installer, pinned: Microsoft's own versioned download link, its size and its
/// SHA-256. Unwine never takes a "latest" link here: a new version from Microsoft comes with a new pin
/// in a new Unwine, so a changed file can never install.
struct WindowsRuntime: Sendable, Identifiable {
    let id: RuntimeID
    /// What the app page says: "Microsoft Visual C++ 2015-2026 (64-bit)".
    let title: String
    let version: String
    let url: URL
    let bytes: Int64
    let sha256: String
    /// Microsoft's documented switches for an install with no questions.
    let arguments: [String]
    /// DLLs that Wine must load from the installed files, not from Wine's own stand-ins.
    var dlls: [String] = []
    /// About how long the install takes on Apple silicon, for the waiting words.
    let minutes: Int
    /// False when the runtime installs but does not work in Wine yet: Unwine says so and offers no Install.
    var works = true

    var fileName: String { "\(id.rawValue)-\(version)-\(url.lastPathComponent)" }
    var megabytes: Int { Int((Double(bytes) / 1_000_000).rounded()) }

    static func pinned(_ id: RuntimeID) -> WindowsRuntime { catalog.first { $0.id == id }! }

    /// The Visual C++ runtime DLLs, for Wine's DLL overrides. MFC needs none: Wine has no MFC.
    private static let vc14DLLs = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                                   "msvcp140_codecvt_ids", "vcomp140", "vcruntime140", "vcruntime140_1"]
    private static func vc(_ year: Int) -> [String] {
        switch year {
        case 2013: return ["msvcp120", "msvcr120", "vcomp120"]
        case 2012: return ["msvcp110", "msvcr110", "vcomp110"]
        case 2010: return ["msvcp100", "msvcr100", "vcomp100"]
        case 2008: return ["msvcp90", "msvcr90", "vcomp90"]
        default: return ["msvcp80", "msvcr80", "vcomp"]
        }
    }

    private static let vcNew = ["/install", "/quiet", "/norestart"]
    /// 2010 to 2013. The 2013 installer (WiX Burn 3.7) waited forever after its checks with
    /// "/install /quiet" under Wine, and finished in 19 s with "/q".
    private static let vcMid = ["/q", "/norestart"]
    /// 2005 and 2008 take no "/norestart".
    private static let vcOld = ["/q"]

    private static func u(_ s: String) -> URL { URL(string: s)! }

    static let catalog: [WindowsRuntime] = [
        WindowsRuntime(id: .vc14x64, title: "Microsoft Visual C++ 2015-2026 (64-bit)", version: "14.51.36247",
                       url: u("https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe"),
                       bytes: 18_731_856, sha256: "843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c",
                       arguments: vcNew, dlls: vc14DLLs, minutes: 1),
        WindowsRuntime(id: .vc14x86, title: "Microsoft Visual C++ 2015-2026 (32-bit)", version: "14.51.36247",
                       url: u("https://download.visualstudio.microsoft.com/download/pr/6ad63323-a427-4c58-8464-9f1f19f62359/F0BAB33A302B3CDB2E11113760D016F54FD3D2632C65BA7834FAC4F0ABD7F1A3/VC_redist.x86.exe"),
                       bytes: 6_941_536, sha256: "f0bab33a302b3cdb2e11113760d016f54fd3d2632c65ba7834fac4f0abd7f1a3",
                       arguments: vcNew, dlls: vc14DLLs, minutes: 1),
        WindowsRuntime(id: .vc2013x64, title: "Microsoft Visual C++ 2013 (64-bit)", version: "12.0.40664",
                       url: u("https://download.visualstudio.microsoft.com/download/pr/10912041/cee5d6bca2ddbcd039da727bf4acb48a/vcredist_x64.exe"),
                       bytes: 7_200_744, sha256: "a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c",
                       arguments: vcMid, dlls: vc(2013), minutes: 1),
        WindowsRuntime(id: .vc2013x86, title: "Microsoft Visual C++ 2013 (32-bit)", version: "12.0.40664",
                       url: u("https://download.visualstudio.microsoft.com/download/pr/10912113/5da66ddebb0ad32ebd4b922fd82e8e25/vcredist_x86.exe"),
                       bytes: 6_510_136, sha256: "53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd",
                       arguments: vcMid, dlls: vc(2013), minutes: 1),
        WindowsRuntime(id: .vc2012x64, title: "Microsoft Visual C++ 2012 (64-bit)", version: "11.0.61030",
                       url: u("https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe"),
                       bytes: 7_186_992, sha256: "681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064",
                       arguments: vcMid, dlls: vc(2012), minutes: 1),
        WindowsRuntime(id: .vc2012x86, title: "Microsoft Visual C++ 2012 (32-bit)", version: "11.0.61030",
                       url: u("https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe"),
                       bytes: 6_554_576, sha256: "b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386",
                       arguments: vcMid, dlls: vc(2012), minutes: 1),
        WindowsRuntime(id: .vc2010x64, title: "Microsoft Visual C++ 2010 (64-bit)", version: "10.0.40219.325",
                       url: u("https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe"),
                       bytes: 10_277_328, sha256: "f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3",
                       arguments: vcMid, dlls: vc(2010), minutes: 1),
        WindowsRuntime(id: .vc2010x86, title: "Microsoft Visual C++ 2010 (32-bit)", version: "10.0.40219.325",
                       url: u("https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe"),
                       bytes: 8_993_744, sha256: "99dce3c841cc6028560830f7866c9ce2928c98cf3256892ef8e6cf755147b0d8",
                       arguments: vcMid, dlls: vc(2010), minutes: 1),
        WindowsRuntime(id: .vc2008x64, title: "Microsoft Visual C++ 2008 (64-bit)", version: "9.0.30729.6161",
                       url: u("https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe"),
                       bytes: 5_211_080, sha256: "c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654",
                       arguments: vcOld, dlls: vc(2008), minutes: 1),
        WindowsRuntime(id: .vc2008x86, title: "Microsoft Visual C++ 2008 (32-bit)", version: "9.0.30729.6161",
                       url: u("https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe"),
                       bytes: 4_483_040, sha256: "8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92",
                       arguments: vcOld, dlls: vc(2008), minutes: 1),
        WindowsRuntime(id: .vc2005x64, title: "Microsoft Visual C++ 2005 (64-bit)", version: "8.0.50727.6195",
                       url: u("https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE"),
                       bytes: 3_179_000, sha256: "4487570bd86e2e1aac29db2a1d0a91eb63361fcaac570808eb327cd4e0e2240d",
                       arguments: vcOld, dlls: vc(2005), minutes: 1),
        WindowsRuntime(id: .vc2005x86, title: "Microsoft Visual C++ 2005 (32-bit)", version: "8.0.50727.6195",
                       url: u("https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE"),
                       bytes: 2_710_520, sha256: "8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd",
                       arguments: vcOld, dlls: vc(2005), minutes: 1),
        WindowsRuntime(id: .netfx48, title: "Microsoft .NET Framework 4.8", version: "4.8.03761",
                       url: u("https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe"),
                       bytes: 121_346_568, sha256: "0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40",
                       arguments: ["/q", "/norestart"], dlls: ["mscoree"], minutes: 10),
        WindowsRuntime(id: .desktop6x64, title: "Microsoft .NET 6 Desktop Runtime (64-bit)", version: "6.0.36",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/6.0.36/windowsdesktop-runtime-6.0.36-win-x64.exe"),
                       bytes: 57_380_656, sha256: "0d20debb26fc8b2bc84f25fbd9d4596a6364af8517ebf012e8b871127b798941",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop6x86, title: "Microsoft .NET 6 Desktop Runtime (32-bit)", version: "6.0.36",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/6.0.36/windowsdesktop-runtime-6.0.36-win-x86.exe"),
                       bytes: 52_173_224, sha256: "4e77bd970df0a06528ee88d33e4a8c9fb85beedbdd7219b017083acf0c3aa39e",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop7x64, title: "Microsoft .NET 7 Desktop Runtime (64-bit)", version: "7.0.20",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/7.0.20/windowsdesktop-runtime-7.0.20-win-x64.exe"),
                       bytes: 58_011_208, sha256: "57e7c16e7226c9a29dbc3faedd9e5876cec494c7660528052f52160521e7b714",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop7x86, title: "Microsoft .NET 7 Desktop Runtime (32-bit)", version: "7.0.20",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/7.0.20/windowsdesktop-runtime-7.0.20-win-x86.exe"),
                       bytes: 53_193_856, sha256: "58d32d9857bda5da99afc217669aedacdffb20aed61f15315718eeb3a455b273",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop8x64, title: "Microsoft .NET 8 Desktop Runtime (64-bit)", version: "8.0.32",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.32/windowsdesktop-runtime-8.0.32-win-x64.exe"),
                       bytes: 58_634_504, sha256: "0f45815f9f032095910af092405c9c6d3844b7fe57252f854d65ed9379b45598",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop8x86, title: "Microsoft .NET 8 Desktop Runtime (32-bit)", version: "8.0.32",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.32/windowsdesktop-runtime-8.0.32-win-x86.exe"),
                       bytes: 53_836_720, sha256: "6402fc8054d310b7660357c82488948aa89b1d7049c106ead4e9a1d1707a8f33",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop9x64, title: "Microsoft .NET 9 Desktop Runtime (64-bit)", version: "9.0.21",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.21/windowsdesktop-runtime-9.0.21-win-x64.exe"),
                       bytes: 60_819_728, sha256: "3e84553cab2edbcb2d5b907d302b1f38d265994522057be65eb9b0361cc19d56",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop9x86, title: "Microsoft .NET 9 Desktop Runtime (32-bit)", version: "9.0.21",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.21/windowsdesktop-runtime-9.0.21-win-x86.exe"),
                       bytes: 55_517_104, sha256: "ce85c2feeb765de38b2bf921742ca150dc022f988120c53229ba1ebcc10a56f5",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop10x64, title: "Microsoft .NET 10 Desktop Runtime (64-bit)", version: "10.0.13",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.13/windowsdesktop-runtime-10.0.13-win-x64.exe"),
                       bytes: 60_056_984, sha256: "f5f0268b3d89ec3b9eb952b620330360b35c63593ead45816aeb26e934a4b7b6",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .desktop10x86, title: "Microsoft .NET 10 Desktop Runtime (32-bit)", version: "10.0.13",
                       url: u("https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.13/windowsdesktop-runtime-10.0.13-win-x86.exe"),
                       bytes: 55_616_984, sha256: "f241cf11d6c0151a0b0eee3f02da4d6a6ef9e21e7d54349056e2d65e6ffb0d73",
                       arguments: vcNew, minutes: 2),
        WindowsRuntime(id: .webview2, title: "Microsoft Edge WebView2", version: "standalone",
                       url: u("https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/35871e19-d11b-432d-9d1e-7be0ff286540/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"),
                       bytes: 214_156_024, sha256: "0625fb5c1e75be58a164e14f95aa58a3e5badb859b3d17c952385f3e4a9ff3e8",
                       // WebView2 draws nothing in Wine 11: Wine has no DirectComposition yet (WineHQ bug 58921).
                       arguments: ["/silent", "/install"], minutes: 3, works: false),
    ]
}
