//
//  HappyQuickAIPrincipal.swift
//  HappyQuickAI
//

import DroppyKit
import Foundation

/// The class Droppy's loader instantiates, named in the bundle's `NSPrincipalClass`.
///
/// It exists only to make one droplet, so keep it empty. Anything done here
/// runs before the host is ready.
@objc(HappyQuickAIPrincipal)
public final class HappyQuickAIPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { HappyQuickAIDroplet() }
}