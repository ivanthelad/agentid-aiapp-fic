# Research: Migrating from Custom FmiTransport to Microsoft.Identity.Web.AgentIdentities

**Date:** 2026-03-11
**Scope:** Autonomous agent flow on Azure Functions (.NET 8)
**Demo:** `demo-functions-dotnet/`

---

## Background

The current .NET demo implements the two-step Agent ID token exchange using `Azure.Identity` with three custom credential classes. Feedback from the Entra team indicated that "for .NET, we fully support all the flows via `Microsoft.Identity.Web`" -- meaning the custom transport approach is unnecessary.

This document analyses the gap between the current implementation and the SDK-native approach using `Microsoft.Identity.Web.AgentIdentities`.

---

## Current Implementation

### Dependencies

```xml
<PackageReference Include="Azure.Identity" Version="1.13.2" />
```

No `Microsoft.Identity.Web` or `Microsoft.Identity.Client` (MSAL) packages.

### Custom Classes (3 files, ~150 lines)

| Class | File | Purpose |
|---|---|---|
| `AgentIdentityBlueprintCredential` | `Credentials/AgentIdentityBlueprintCredential.cs` | Wraps MSI token as a `ClientAssertion` to `ClientAssertionCredential` to get a blueprint exchange token (T1) |
| `FmiTransport` | `Credentials/FmiTransport.cs` | Custom `HttpClientTransport` that intercepts POST requests to `oauth2/v2.0/token` and manually appends `fmi_path=<agentIdentityId>` to the form-urlencoded body |
| `AgentIdentityCredential` | `Credentials/AgentIdentityCredential.cs` | Orchestrates the full two-step exchange: T1 (via `BlueprintCredential` + `FmiTransport`) → TR (resource token) |

### Token Flow

```
ManagedIdentityCredential (MSI token)
  → ClientAssertionCredential + FmiTransport (injects fmi_path into POST body)
    → Blueprint exchange token (T1)
      → ClientAssertionCredential (T1 as assertion)
        → Resource token (TR), oid = agent identity
```

### How FmiTransport Works

`FmiTransport` extends `HttpClientTransport` and overrides `Process`/`ProcessAsync`. For every HTTP request:

1. Checks if it's a POST to `oauth2/v2.0/token`
2. Reads the existing form body from `message.Request.Content` into a `MemoryStream`
3. Appends `&fmi_path=<agentIdentityId>` (URL-escaped) to the body string
4. Replaces the request content with the modified body

This approach was based on the [App Service Agent Identity docs](https://learn.microsoft.com/en-us/azure/app-service/overview-agent-identity) which showed `AppendQuery` for URL-based injection, but the Entra token endpoint requires `fmi_path` in the POST body.

### Risks with Current Approach

- **Fragile:** String manipulation of form-encoded bodies may break if Azure.Identity changes internal encoding, adds parameters, or changes content handling
- **No token caching:** Each call constructs a new `ClientAssertionCredential`, MSAL's token cache is not utilised
- **Undocumented pattern:** The form-body injection via custom transport is not a documented or supported Entra pattern
- **Maintenance burden:** ~150 lines of code that must be understood and maintained

---

## Proposed Approach: Microsoft.Identity.Web.AgentIdentities

### Reference Implementation

The [Dayzure/ai-agent-with-id](https://github.com/Dayzure/ai-agent-with-id/tree/main/DigitialWorkerWithTools/Authentication) repository demonstrates the SDK-native approach. Their implementation uses:

- `Microsoft.Identity.Client` (MSAL) -- `ConfidentialClientApplicationBuilder`
- `Microsoft.Identity.Web.AgentIdentities` -- provides the `.WithFmiPath()` extension method

### Required Package Additions

```xml
<!-- Replace Azure.Identity with MSAL + Microsoft.Identity.Web -->
<PackageReference Include="Microsoft.Identity.Client" Version="4.78.0" />
<PackageReference Include="Microsoft.Identity.Web.AgentIdentities" Version="4.0.1" />

<!-- Keep Azure.Identity only for ManagedIdentityCredential -->
<PackageReference Include="Azure.Identity" Version="1.13.2" />
```

### How .WithFmiPath() Replaces FmiTransport

The `Microsoft.Identity.Web.AgentIdentities` package adds an extension method to MSAL's `AcquireTokenForClientParameterBuilder`:

```csharp
// SDK-native fmi_path -- one line replaces the entire FmiTransport class
var t1 = await blueprintApp
    .AcquireTokenForClient(new[] { "api://AzureADTokenExchange/.default" })
    .WithFmiPath(agentIdentityId)
    .ExecuteAsync();
```

Internally, `.WithFmiPath()` adds the `fmi_path` parameter to the token request through MSAL's supported extension mechanism -- no HTTP interception needed.

### Equivalent Autonomous Flow

The two-step exchange remains identical. Only the mechanism changes:

```csharp
// --- Step 1: MSI → Blueprint exchange token (T1) with fmi_path ---
var blueprintApp = ConfidentialClientApplicationBuilder
    .Create(blueprintClientId)
    .WithAuthority($"https://login.microsoftonline.com/{tenantId}")
    .WithClientAssertion(async (options) =>
    {
        var msi = new ManagedIdentityCredential(managedIdentityClientId);
        return (await msi.GetTokenAsync(
            new TokenRequestContext(new[] { "api://AzureADTokenExchange/.default" })
        )).Token;
    })
    .Build();

var t1 = await blueprintApp
    .AcquireTokenForClient(new[] { "api://AzureADTokenExchange/.default" })
    .WithFmiPath(agentIdentityId)    // ← replaces FmiTransport
    .ExecuteAsync();

// --- Step 2: T1 → Resource token (TR) ---
var agentApp = ConfidentialClientApplicationBuilder
    .Create(agentIdentityId)
    .WithAuthority($"https://login.microsoftonline.com/{tenantId}")
    .WithClientAssertion(async (options) => t1.AccessToken)
    .Build();

var resourceToken = await agentApp
    .AcquireTokenForClient(new[] { "https://storage.azure.com/.default" })
    .ExecuteAsync();
// resourceToken.AccessToken has oid = agent identity (for RBAC)
```

### TokenCredential Wrapper Consideration

The current `AgentIdentityCredential` extends `Azure.Core.TokenCredential`, which lets it plug directly into Azure SDK clients:

```csharp
var blobClient = new BlobServiceClient(uri, new AgentIdentityCredential(...));
```

With MSAL, `AcquireTokenForClient` returns `AuthenticationResult`, not a `TokenCredential`. A thin wrapper (~30 lines) would be needed to maintain the same Azure SDK integration:

```csharp
internal class AgentIdentityCredential : TokenCredential
{
    private readonly IConfidentialClientApplication _blueprintApp;
    private readonly IConfidentialClientApplication _agentApp;
    private readonly string _agentIdentityId;

    // constructor builds both MSAL apps...

    public override async ValueTask<AccessToken> GetTokenAsync(
        TokenRequestContext requestContext, CancellationToken ct)
    {
        var t1 = await _blueprintApp
            .AcquireTokenForClient(new[] { "api://AzureADTokenExchange/.default" })
            .WithFmiPath(_agentIdentityId)
            .ExecuteAsync(ct);

        var tr = await _agentApp
            .AcquireTokenForClient(requestContext.Scopes.ToArray())
            .ExecuteAsync(ct);

        return new AccessToken(tr.AccessToken, tr.ExpiresOn);
    }
}
```

---

## Comparison

| Aspect | Current (FmiTransport) | Microsoft.Identity.Web |
|---|---|---|
| **fmi_path injection** | Custom `HttpClientTransport` -- intercepts raw POST body | `.WithFmiPath()` extension -- one SDK call |
| **Token library** | `Azure.Identity` (`ClientAssertionCredential`) | MSAL (`ConfidentialClientApplication`) + `Microsoft.Identity.Web.AgentIdentities` |
| **Token caching** | None -- new credential per request | MSAL built-in in-memory token cache |
| **Retry / resilience** | Inherits base `HttpClientTransport` defaults | MSAL's built-in retry and throttling |
| **Custom code** | ~150 lines across 3 files | ~30-40 lines in 1 file (TokenCredential wrapper) |
| **Files to delete** | -- | `FmiTransport.cs`, `AgentIdentityBlueprintCredential.cs` |
| **Supported pattern** | Undocumented -- based on App Service docs example | First-party SDK, maintained by the Identity team |
| **Agent flow** | Autonomous (two-step) | Supports autonomous, interactive, and Digital Colleague flows |

---

## Dayzure Reference Notes

The [Dayzure implementation](https://github.com/Dayzure/ai-agent-with-id/blob/main/DigitialWorkerWithTools/Authentication/FicTokenCredential.cs) demonstrates the **Digital Colleague (`user_fic`) flow** which is more complex than the autonomous flow used here:

- Uses `grant_type=user_fic` with `requested_token_use=on_behalf_of`
- Includes `user_federated_identity_credential` and `username` parameters
- Still has a raw HTTP POST for the final `user_fic` exchange (MSAL doesn't natively support this grant type yet)

For our **autonomous agent** use case, the migration is simpler -- `.WithFmiPath()` on `AcquireTokenForClient()` fully covers the flow without any raw HTTP calls.

---

## Migration Steps (if proceeding)

1. **Add NuGet packages:** `Microsoft.Identity.Client` and `Microsoft.Identity.Web.AgentIdentities`
2. **Rewrite `AgentIdentityCredential.cs`** to use MSAL with `.WithFmiPath()` (see wrapper pattern above)
3. **Delete `FmiTransport.cs`** -- fully replaced by `.WithFmiPath()`
4. **Delete `AgentIdentityBlueprintCredential.cs`** -- absorbed into the rewritten credential
5. **Update `AgentFunctions.cs`** -- no changes needed if `AgentIdentityCredential` keeps the same constructor signature and `TokenCredential` base class
6. **Update README.md** -- remove FmiTransport documentation, reference `.WithFmiPath()`
7. **Build and test** -- token flow should be identical, verify `oid` claim in resource token

---

## Conclusion

The migration is straightforward for the autonomous flow. `.WithFmiPath()` is a direct, supported replacement for `FmiTransport`. The main benefit is reducing ~150 lines of fragile custom transport code to ~30 lines of SDK-native calls, with the added bonus of MSAL's token caching and retry logic.

---

## References

- [Microsoft.Identity.Web.AgentIdentities NuGet](https://www.nuget.org/packages/Microsoft.Identity.Web.AgentIdentities)
- [Dayzure/ai-agent-with-id — FicTokenCredential.cs](https://github.com/Dayzure/ai-agent-with-id/blob/main/DigitialWorkerWithTools/Authentication/FicTokenCredential.cs)
- [App Service Agent Identity docs (original source)](https://learn.microsoft.com/en-us/azure/app-service/overview-agent-identity)
- [Microsoft.Identity.Client — ConfidentialClientApplicationBuilder](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/web-apps-apis/confidential-client-application)
