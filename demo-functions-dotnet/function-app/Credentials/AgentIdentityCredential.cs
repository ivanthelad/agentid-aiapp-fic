using Azure.Core;
using Azure.Identity;

namespace AgentFunctionsDotnet.Credentials;

/// <summary>
/// Two-step token exchange for Agent ID on Azure Functions using SDK-native fmi_path.
///
/// Step 1: MSI → Blueprint exchange token (T1)
///         Uses AgentIdentityBlueprintCredential with FmiTransport to inject fmi_path.
///         The FmiTransport appends fmi_path=agentIdentityId as a query parameter.
///
/// Step 2: T1 → Resource token (TR)
///         Standard ClientAssertionCredential using T1 as the client assertion.
///         The resulting token has oid = agent identity (for RBAC).
///
/// Unlike the Python demo which uses raw HTTP POST (because Python SDKs lack fmi_path),
/// this .NET implementation uses the SDK-native approach documented by Microsoft:
/// https://learn.microsoft.com/en-us/azure/app-service/overview-agent-identity
/// </summary>
internal class AgentIdentityCredential : TokenCredential
{
    private static readonly string TokenExchangeAudience =
        Environment.GetEnvironmentVariable("TokenExchangeAudience") ?? "api://AzureADTokenExchange";

    private static readonly string PublicTokenExchangeScope = $"{TokenExchangeAudience}/.default";

    private readonly ClientAssertionCredential _innerCredential;

    public AgentIdentityCredential(
        string tenantId,
        string agentIdentityBlueprintId,
        string managedIdentityClientId,
        string agentIdentityId)
    {
        // Step 1 credential: blueprint with FmiTransport injecting fmi_path
        var blueprintCredential = new AgentIdentityBlueprintCredential(
            tenantId,
            agentIdentityBlueprintId,
            managedIdentityClientId,
            new ClientAssertionCredentialOptions
            {
                Transport = new FmiTransport(agentIdentityId)
            });

        // Step 2 credential: use T1 (blueprint exchange token) as assertion
        Func<CancellationToken, Task<string>> clientAssertionCallback = async (CancellationToken cancellationToken) =>
            (await blueprintCredential.GetTokenAsync(
                new TokenRequestContext([PublicTokenExchangeScope]),
                cancellationToken)).Token;

        _innerCredential = new ClientAssertionCredential(tenantId, agentIdentityId, clientAssertionCallback);
    }

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => _innerCredential.GetToken(requestContext, cancellationToken);

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => _innerCredential.GetTokenAsync(requestContext, cancellationToken);
}
