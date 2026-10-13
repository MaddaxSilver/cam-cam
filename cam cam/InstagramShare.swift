//
//  InstagramShare.swift
//  cam cam
//
//  Post a photo straight into Instagram from the gallery.
//
//  • Feed: opens Instagram's composer with the photo from your library
//    (instagram://library?LocalIdentifier=…). No account setup needed.
//  • Story: Instagram's Stories hand-off puts the image on a private
//    pasteboard and opens instagram-stories://share. Since 2023 Instagram
//    only accepts it with a Meta (Facebook) App ID — set `MetaAppID` in
//    Info.plist. Until then (or if Instagram isn't installed) the share
//    sheet opens instead, which also lists Instagram.
//

import Photos
import UIKit

enum InstagramShare {
    static var installed: Bool {
        guard let u = URL(string: "instagram://app") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    static var metaAppID: String {
        (Bundle.main.object(forInfoDictionaryKey: "MetaAppID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Open Instagram's new-post composer with this library photo.
    /// Returns false if Instagram couldn't be opened.
    @discardableResult
    static func postToFeed(assetID: String) -> Bool {
        guard installed,
              let id = assetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "instagram://library?LocalIdentifier=\(id)") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// Hand the image to Instagram Stories as the background.
    /// Returns false when Stories can't be used (no App ID / not installed).
    @discardableResult
    static func shareToStory(_ image: UIImage) -> Bool {
        let appID = metaAppID
        guard installed, !appID.isEmpty,
              let url = URL(string: "instagram-stories://share?source_application=\(appID)"),
              UIApplication.shared.canOpenURL(url),
              let data = image.jpegData(compressionQuality: 0.92) else { return false }
        UIPasteboard.general.setItems([["com.instagram.sharedSticker.backgroundImage": data]],
                                      options: [.expirationDate: Date().addingTimeInterval(300)])
        UIApplication.shared.open(url)
        return true
    }

    /// Fallback: the system share sheet (Instagram is listed there too).
    static func shareSheet(_ image: UIImage) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}
