using Azure.Core;
using Azure.Core.Pipeline;

namespace AgentFunctionsDotnet.Credentials;

/// <summary>
/// Custom HTTP transport that injects fmi_path into token endpoint requests.
/// This tells Entra which child agent identity to impersonate during the token exchange.
///
/// Based on: https://learn.microsoft.com/en-us/azure/app-service/overview-agent-identity
///
/// The MS docs show AppendQuery, but the Entra token endpoint requires fmi_path
/// in the POST body (form-urlencoded), not as a URL query parameter.
/// This transport intercepts POST requests to the token endpoint and appends
/// fmi_path to the form body.
/// </summary>
public class FmiTransport(string agentIdentityId) : HttpClientTransport()
{
    public override void Process(HttpMessage message)
    {
        InjectFmiPath(message);
        base.Process(message);
    }

    public override ValueTask ProcessAsync(HttpMessage message)
    {
        InjectFmiPath(message);
        return base.ProcessAsync(message);
    }

    private void InjectFmiPath(HttpMessage message)
    {
        // Only modify POST requests to the token endpoint
        if (message.Request.Method != RequestMethod.Post)
            return;

        var uri = message.Request.Uri.ToString();
        if (!uri.Contains("oauth2/v2.0/token", StringComparison.OrdinalIgnoreCase))
            return;

        if (message.Request.Content is null)
            return;

        // Read existing form body
        using var ms = new MemoryStream();
        message.Request.Content.WriteTo(ms, default);
        var existingBody = System.Text.Encoding.UTF8.GetString(ms.ToArray());

        // Append fmi_path
        var newBody = existingBody + "&fmi_path=" + Uri.EscapeDataString(agentIdentityId);
        message.Request.Content = RequestContent.Create(System.Text.Encoding.UTF8.GetBytes(newBody));
    }
}
