// Swift currently has no supported whole-module re-export spelling. `public
// import` permits protocol types in this module's public signatures, but does
// not make the remaining generated request builders available to SDK clients.
// Keep this narrowly scoped compatibility attribute until Swift provides an
// equivalent public re-export; plugin authors intentionally need one import.
@_exported import OnelastleafPluginProtocol
