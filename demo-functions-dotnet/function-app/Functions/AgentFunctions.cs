using System.Text.Json;
using AgentFunctionsDotnet.Credentials;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace AgentFunctionsDotnet.Functions;

public class AgentFunctions(ILogger<AgentFunctions> logger)
{
    private static readonly string TenantId = Environment.GetEnvironmentVariable("TENANT_ID") ?? "";
    private static readonly string BlueprintClientId = Environment.GetEnvironmentVariable("BLUEPRINT_CLIENT_ID") ?? "";
    private static readonly string MiClientId = Environment.GetEnvironmentVariable("MI_CLIENT_ID") ?? "";
    private static readonly string AgentIdentityId = Environment.GetEnvironmentVariable("AGENT_IDENTITY_ID") ?? "";
    private static readonly string StorageAccountName = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME") ?? "";
    private static readonly string StorageContainer = Environment.GetEnvironmentVariable("STORAGE_CONTAINER") ?? "agent-demo";

    private const int WriteThrottleSuccess = 60;
    private const int WriteThrottleFail = 5;

    private static readonly object WriteLock = new();
    private static string? _lastStatus;
    private static string? _lastBlob;
    private static DateTime? _lastTimestamp;
    private static string? _lastError;

    [Function("write-status")]
    public async Task<IActionResult> WriteStatus([HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequest req)
    {
        var now = DateTime.UtcNow;
        var result = new Dictionary<string, object?>
        {
            ["source"] = "azure-functions-dotnet",
            ["agent_identity"] = string.IsNullOrEmpty(AgentIdentityId) ? "(not configured)" : AgentIdentityId,
            ["storage_account"] = string.IsNullOrEmpty(StorageAccountName) ? "(not configured)" : StorageAccountName,
        };

        // Check throttle window
        lock (WriteLock)
        {
            if (_lastTimestamp.HasValue)
            {
                var elapsed = (now - _lastTimestamp.Value).TotalSeconds;
                var cooldown = _lastStatus == "success-write" ? WriteThrottleSuccess : WriteThrottleFail;
                if (elapsed < cooldown)
                {
                    result["status"] = _lastStatus;
                    result["blob"] = _lastBlob;
                    result["timestamp"] = _lastTimestamp.Value.ToString("O");
                    result["error"] = _lastError;
                    result["throttled"] = true;
                    result["next_write_in"] = (int)(cooldown - elapsed);
                    return new OkObjectResult(result);
                }
            }
        }

        // Validate config
        var missing = new List<string>();
        if (string.IsNullOrEmpty(TenantId)) missing.Add("TENANT_ID");
        if (string.IsNullOrEmpty(BlueprintClientId)) missing.Add("BLUEPRINT_CLIENT_ID");
        if (string.IsNullOrEmpty(MiClientId)) missing.Add("MI_CLIENT_ID");
        if (string.IsNullOrEmpty(AgentIdentityId)) missing.Add("AGENT_IDENTITY_ID");
        if (string.IsNullOrEmpty(StorageAccountName)) missing.Add("STORAGE_ACCOUNT_NAME");

        if (missing.Count > 0)
        {
            result["status"] = "fail-write";
            result["error"] = $"Missing config: {string.Join(", ", missing)}";
            return new ObjectResult(result) { StatusCode = 500 };
        }

        try
        {
            // SDK-native two-step token exchange via FmiTransport
            var credential = new AgentIdentityCredential(
                TenantId, BlueprintClientId, MiClientId, AgentIdentityId);

            var blobServiceClient = new BlobServiceClient(
                new Uri($"https://{StorageAccountName}.blob.core.windows.net"),
                credential);

            var containerClient = blobServiceClient.GetBlobContainerClient(StorageContainer);
            var blobName = $"heartbeat/functions-dotnet-{now:yyyyMMddTHHmmss}.json";

            var payload = JsonSerializer.Serialize(new
            {
                source = "azure-functions-dotnet",
                timestamp = now.ToString("O"),
                agent_identity = AgentIdentityId,
                blueprint = BlueprintClientId,
            });

            await containerClient.UploadBlobAsync(blobName, BinaryData.FromString(payload));

            lock (WriteLock)
            {
                _lastStatus = "success-write";
                _lastBlob = blobName;
                _lastTimestamp = now;
                _lastError = null;
            }

            result["status"] = "success-write";
            result["blob"] = blobName;
            result["timestamp"] = now.ToString("O");
            result["error"] = null;
            result["throttled"] = false;

            logger.LogInformation("Blob write succeeded: {BlobName}", blobName);
            return new OkObjectResult(result);
        }
        catch (Exception ex)
        {
            var fullError = ex.InnerException != null
                ? $"{ex.Message} -> {ex.InnerException.Message}"
                : ex.Message;

            lock (WriteLock)
            {
                _lastStatus = "fail-write";
                _lastBlob = null;
                _lastTimestamp = now;
                _lastError = fullError;
            }

            result["status"] = "fail-write";
            result["timestamp"] = now.ToString("O");
            result["error"] = fullError;
            result["throttled"] = false;

            logger.LogError(ex, "Blob write failed");
            return new ObjectResult(result) { StatusCode = 500 };
        }
    }

    [Function("health")]
    public IActionResult Health([HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequest req)
    {
        return new OkObjectResult("ok");
    }
}
