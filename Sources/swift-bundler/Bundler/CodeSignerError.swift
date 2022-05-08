import Foundation

/// An error returned by ``CodeSigner``.
enum CodeSignerError: LocalizedError {
  case failedToEnumerateIdentities(ProcessError)
  case failedToParseIdentityList(Error)
  case failedToRunCodesignTool(ProcessError)
  case failedToWriteEntitlements(Error)
  case failedToVerifyProvisioningProfile(ProcessError)
  case failedToDeserializeProvisioningProfile(Error)
  case provisioningProfileMissingTeamIdentifier
}