import RitrovoCore
import SwiftUI

/// Credits: the only place where the recovery engine is named.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ritrovo").font(.system(size: 22, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: loc("Recovery engine"))
                Text("PhotoRec, by Christophe Grenier · CGSecurity").font(.system(size: 13, weight: .medium))
                Link("www.cgsecurity.org", destination: URL(string: "https://www.cgsecurity.org")!)
                    .font(.system(size: 12))
                Text("Every file is found and rebuilt by PhotoRec, included with its recognition algorithms unchanged. Ritrovo is a macOS interface and not an official CGSecurity product.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                Text("Free software, GNU General Public License version 2 or later, without any warranty.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Link("License text", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
                    .font(.system(size: 11))
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }
}
