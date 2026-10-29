enum BuildEdition {
#if WRAPPIN_SBB_EDITION
    static let isSBBEdition = true
    static let supportsBuiltInTunnel = false
    static let callbackScheme = "wrappinsbb"
    static let supportsUpstreamReleaseUpdates = false
#elseif WRAPPIN_TUNNEL_EDITION
    static let isSBBEdition = false
    static let supportsBuiltInTunnel = true
    static let callbackScheme = "wrappintunnel"
    static let supportsUpstreamReleaseUpdates = true
#else
    static let isSBBEdition = false
    static let supportsBuiltInTunnel = false
    static let callbackScheme = "wrappin"
    static let supportsUpstreamReleaseUpdates = true
#endif
}
