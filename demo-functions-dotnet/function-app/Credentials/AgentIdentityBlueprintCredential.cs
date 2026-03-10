using Azure.Core;
using Azure.Identity;

namespace AgentFunctionsDotnet.Credentials;

/// <summary>
/// Wraps a User-Assigned Managed Identity to produce blueprint exchange tokens.
/// The MSI token is used as a client assertion for the blueprint's ClientAssertionCredential.
///
/// Token flow: MSI → ClientAssertionCredential → blueprint exchange token
///
/// When used with FmiTransport (via ClientAssertionCredentialOptions.Transport),
/// the fmi_path query parameter is injected to target a specific agent identity.
///
/// Source: https://learn.microsoft.com/en-us/azure/app-service/overview-agent-identity
/// </summary>
internal class AgentIdentityBlueprintCredential : TokenCredential
{
    private static readonly string TokenExchangeAudience =
        Environment.GetEnvironmentVariable("TokenExchangeAudience") ?? "api://AzureADTokenExchange";

    private static readonly string PublicTokenExchangeScope = $"{TokenExchangeAudience}/.default";

    private readonly ClientAssertionCredential _innerCredential;

    public AgentIdentityBlueprintCredential(
        string tenantId,
        string agentIdentityBlueprintId,
        string managedIdentityClientId,
        ClientAssertionCredentialOptions? options = null)
    {
        var managedIdentityCredential = new ManagedIdentityCredential(managedIdentityClientId);

        Func<CancellationToken, Task<string>> clientAssertionCallback = async (CancellationToken cancellationToken) =>
            (await managedIdentityCredential.GetTokenAsync(
                new TokenRequestContext([PublicTokenExchangeScope]),
                cancellationToken)).Token;

        _innerCredential = options is null
            ? new ClientAssertionCredential(tenantId, agentIdentityBlueprintId, clientAssertionCallback)
            : new ClientAssertionCredential(tenantId, agentIdentityBlueprintId, clientAssertionCallback, options);
    }

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => _innerCredential.GetToken(requestContext, cancellationToken);

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => _innerCredential.GetTokenAsync(requestContext, cancellationToken);
}
