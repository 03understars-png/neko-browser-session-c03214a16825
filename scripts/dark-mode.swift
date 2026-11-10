import Foundation
let dark = CommandLine.arguments.dropFirst().first != "light"
typealias SetTheme = @convention(c) (Bool) -> Void
guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      let symbol = dlsym(skylight, "SLSSetAppearanceThemeLegacy") else {
  FileHandle.standardError.write("SkyLight has no appearance switch here\n".data(using: .utf8)!)
  exit(1)
}
unsafeBitCast(symbol, to: SetTheme.self)(dark)
print(dark ? "dark" : "light")
