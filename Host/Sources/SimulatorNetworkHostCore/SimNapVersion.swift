import Foundation

/// The one place the macOS app and CLI version is written.
///
/// `Scripts/build-app.sh` reads this value rather than carrying its own, so
/// the bundle, `--version` and the menu cannot drift apart — which they
/// already had once, with the app bundle reporting 1.0.1 under an app/1.0.2
/// tag.
///
/// Bump this, then tag `app/<version>`.
public enum SimNapVersion {
    public static let current = "1.0.3"
}
