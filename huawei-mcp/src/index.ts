#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
    CallToolRequestSchema,
    ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as dotenv from "dotenv";
import * as fs from "fs";
import * as path from "path";

dotenv.config({ path: path.resolve(process.cwd(), ".env") });
dotenv.config({ path: path.resolve(process.cwd(), "../.env") });

const workspaceRoot = process.cwd();
const possibleHuaweiDirs = [
  path.resolve(workspaceRoot, "huawei"),
  path.resolve(workspaceRoot, "../huawei"),
  path.resolve(workspaceRoot, "../production final/huawei"),
  path.resolve(workspaceRoot, "../../production final/huawei"),
  path.resolve(workspaceRoot, "C:/Users/Bojan/Desktop/production final/huawei"),
  path.resolve(workspaceRoot, "C:/Users/Bojan/Desktop/production final"),
];

function findExistingFile(fileNames: string[], searchRoots: string[]): string | null {
  for (const root of searchRoots) {
    if (!root || !fs.existsSync(root)) continue;
    for (const fileName of fileNames) {
      const candidate = path.join(root, fileName);
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
        return candidate;
      }
    }
  }
  return null;
}

const HUAWEI_DIR = possibleHuaweiDirs.find((p) => fs.existsSync(p) && fs.statSync(p).isDirectory()) || null;
const AGCONNECT_PATH =
  process.env.HUAWEI_AGCONNECT_PATH ||
  findExistingFile(["agconnect-services.json"], HUAWEI_DIR ? [HUAWEI_DIR] : possibleHuaweiDirs) ||
  findExistingFile(["agconnect-services.json"], [path.resolve(workspaceRoot, ".."), path.resolve(workspaceRoot, "../..")]);

const HUAWEI_TXT_PATH =
  process.env.HUAWEI_TXT_PATH ||
  findExistingFile(["HUAWEI.txt"], HUAWEI_DIR ? [HUAWEI_DIR] : possibleHuaweiDirs) ||
  findExistingFile(["HUAWEI.txt"], [path.resolve(workspaceRoot, ".."), path.resolve(workspaceRoot, "../..")]);

function loadApiClientCreds(): { client_id: string; client_secret: string } {
  const dirs = [...(HUAWEI_DIR ? [HUAWEI_DIR] : []), ...possibleHuaweiDirs];
  for (const dir of dirs) {
    try {
      if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) continue;
      for (const fileName of fs.readdirSync(dir)) {
        if (!fileName.startsWith("agc-apiclient-") || !fileName.endsWith(".json")) continue;
        try {
          const parsed = JSON.parse(fs.readFileSync(path.join(dir, fileName), "utf8"));
          if (parsed?.client_id && parsed?.client_secret) return parsed;
        } catch {
          continue;
        }
      }
    } catch {
      continue;
    }
  }
  return { client_id: "", client_secret: "" };
}

const apiClientCreds = loadApiClientCreds();
const HUAWEI_CLIENT_ID = process.env.HUAWEI_CLIENT_ID || process.env.HUAWEI_APP_CLIENT_ID || apiClientCreds.client_id;
const HUAWEI_CLIENT_SECRET = process.env.HUAWEI_CLIENT_SECRET || apiClientCreds.client_secret;
const HUAWEI_APP_ID = process.env.HUAWEI_APP_ID || "";
const HUAWEI_PACKAGE_NAME = process.env.HUAWEI_PACKAGE_NAME || "";
const HUAWEI_PROJECT_ID = process.env.HUAWEI_PROJECT_ID || "";

function safeReadFile(filePath: string | null): string | null {
  if (!filePath) return null;
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
}

function parseAgconnect(): Record<string, any> | null {
  const raw = safeReadFile(AGCONNECT_PATH);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as Record<string, any>;
  } catch {
    return null;
  }
}

function parseHuaweiTxt(): Record<string, string> {
  const raw = safeReadFile(HUAWEI_TXT_PATH);
  if (!raw) return {};

  const result: Record<string, string> = {};
  const lines = raw.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("=")) continue;
    const idx = trimmed.indexOf(":");
    if (idx > 0) {
      const key = trimmed.slice(0, idx).trim();
      const value = trimmed.slice(idx + 1).trim();
      if (key) result[key] = value;
    }
  }
  return result;
}

function summarizeAgconnect(data: Record<string, any> | null) {
  if (!data) {
    return {
      found: false,
      package_name: null,
      app_id: null,
      project_id: null,
      client_id: null,
      client_secret_present: false,
      api_key_present: false,
    };
  }

  const client = data.client || {};
  const appInfo = data.app_info || {};
  return {
    found: true,
    package_name: appInfo.package_name || client.package_name || HUAWEI_PACKAGE_NAME || null,
    app_id: appInfo.app_id || client.app_id || HUAWEI_APP_ID || null,
    project_id: client.project_id || HUAWEI_PROJECT_ID || null,
    client_id: client.client_id || HUAWEI_CLIENT_ID || null,
    client_secret_present: Boolean(client.client_secret || HUAWEI_CLIENT_SECRET),
    api_key_present: Boolean(client.api_key),
  };
}

async function testHuaweiOAuth(): Promise<Record<string, any>> {
  if (!HUAWEI_CLIENT_ID || !HUAWEI_CLIENT_SECRET) {
    return {
      ok: false,
      error: "Missing HUAWEI_CLIENT_ID or HUAWEI_CLIENT_SECRET environment variables.",
    };
  }

  try {
    const response = await fetch("https://connect-api.cloud.huawei.com/api/oauth2/v1/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": "curl/8.0",
      },
      body: JSON.stringify({
        grant_type: "client_credentials",
        client_id: HUAWEI_CLIENT_ID,
        client_secret: HUAWEI_CLIENT_SECRET,
      }),
    });

    const text = await response.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = { raw: text };
    }

    if (!response.ok) {
      return {
        ok: false,
        status: response.status,
        error: json?.error_description || json?.error || "Huawei OAuth failed.",
        response: json,
      };
    }

    return {
      ok: true,
      status: response.status,
      access_token_present: Boolean(json?.access_token),
      token_type: json?.token_type || null,
      expires_in: json?.expires_in || null,
      response: json,
    };
  } catch (error: any) {
    return {
      ok: false,
      error: error?.message || "Unexpected error while calling Huawei OAuth endpoint.",
    };
  }
}

// --- Connect API helpers ---------------------------------------------------

const AGC_API_BASE = "https://connect-api.cloud.huawei.com/api";
let cachedToken: { token: string; expiresAt: number } | null = null;

const RELEASE_STATE_LABELS: Record<number, string> = {
  0: "released",
  1: "release rejected",
  2: "removed (incl. forcible)",
  3: "releasing",
  4: "reviewing",
  5: "pending update review",
  6: "removal requested",
  7: "draft",
  8: "update rejected",
  9: "removal rejected",
  10: "removed by developer",
  11: "release canceled",
  12: "under pre-review",
  13: "pre-review failed",
};

function resolveAppId(args: Record<string, any> | undefined): string {
  const argId = args?.appId;
  if (argId) return String(argId);
  if (HUAWEI_APP_ID) return HUAWEI_APP_ID;
  const txtId = parseHuaweiTxt()["App ID"];
  if (txtId) return txtId;
  return "";
}

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.token;
  }
  const result = await testHuaweiOAuth();
  if (!result.ok || !result.response?.access_token) {
    throw new Error(`Huawei OAuth failed: ${JSON.stringify(result)}`);
  }
  const expiresIn = Number(result.response.expires_in || 28800);
  cachedToken = {
    token: result.response.access_token,
    expiresAt: Date.now() + expiresIn * 1000,
  };
  return cachedToken.token;
}

async function agcRequest(
  method: "GET" | "POST" | "PUT" | "DELETE",
  apiPath: string,
  body?: unknown,
): Promise<any> {
  const token = await getAccessToken();
  const url = apiPath.startsWith("http")
    ? apiPath
    : `${AGC_API_BASE}/${apiPath.replace(/^\/+/, "").replace(/^api\//, "")}`;
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      client_id: HUAWEI_CLIENT_ID,
      "User-Agent": "curl/8.0",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    return { httpStatus: response.status, raw: text };
  }
}

function toolJson(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

const server = new Server(
  {
    name: "huawei-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "huawei_get_config_summary",
      description: "Read Huawei AppGallery config and summarize app metadata from agconnect-services.json or environment variables.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "huawei_validate_config",
      description: "Validate Huawei AppGallery config file and report missing fields.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "huawei_get_release_checklist",
      description: "Get a practical checklist to publish an Android app on Huawei AppGallery.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "huawei_test_oauth",
      description: "Attempt to authenticate with Huawei AppGallery OAuth using configured client credentials.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
      },
    },
    {
      name: "huawei_get_app_info",
      description: "Query AppGallery Connect app info (Publishing API app-info): release state, on-shelf version, pending version, audit opinion, release country/phasing.",
      inputSchema: {
        type: "object",
        properties: {
          appId: { type: "string", description: "AppGallery app ID. Defaults to HUAWEI_APP_ID env / HUAWEI.txt." },
          lang: { type: "string", description: "Language code to filter app info (e.g. 'sr')." },
          releaseType: { type: "number", description: "1 = full release (default), 3 = phased release." },
        },
        required: [],
      },
    },
    {
      name: "huawei_get_release_status",
      description: "Decoded release summary: on-shelf vs pending version, releaseState label, release phase, country, audit opinion.",
      inputSchema: {
        type: "object",
        properties: {
          appId: { type: "string", description: "AppGallery app ID. Defaults to HUAWEI_APP_ID env / HUAWEI.txt." },
        },
        required: [],
      },
    },
    {
      name: "huawei_get_app_id",
      description: "Resolve AppGallery app ID from a package name via the appid-list API.",
      inputSchema: {
        type: "object",
        properties: {
          packageName: { type: "string", description: "Android package name, e.g. com.gavra013.gavra_android" },
        },
        required: ["packageName"],
      },
    },
    {
      name: "huawei_get_compile_status",
      description: "Query AAB package compile/parsing status on AppGallery for a given pkgVersion (returned by app-file-info update).",
      inputSchema: {
        type: "object",
        properties: {
          appId: { type: "string", description: "AppGallery app ID. Defaults to HUAWEI_APP_ID env / HUAWEI.txt." },
          pkgVersion: { type: "string", description: "Package version string returned by the upload/app-file-info call." },
        },
        required: ["pkgVersion"],
      },
    },
    {
      name: "huawei_api_request",
      description: "Call any AppGallery Connect API endpoint (OAuth handled). Use for APIs without a dedicated tool, e.g. 'publish/v2/app-submit?appid=...'.",
      inputSchema: {
        type: "object",
        properties: {
          method: { type: "string", enum: ["GET", "POST", "PUT", "DELETE"], description: "HTTP method." },
          path: { type: "string", description: "Path under https://connect-api.cloud.huawei.com/api/, e.g. 'publish/v2/app-info?appId=123'. Full URLs also accepted." },
          body: { type: "object", description: "Optional JSON body for POST/PUT." },
        },
        required: ["method", "path"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "huawei_get_config_summary": {
      const agc = parseAgconnect();
      const txt = parseHuaweiTxt();
      const summary = summarizeAgconnect(agc);

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                config_file: AGCONNECT_PATH || null,
                txt_file: HUAWEI_TXT_PATH || null,
                appgallery_dir: HUAWEI_DIR || null,
                summary,
                txt_fields: txt,
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    case "huawei_validate_config": {
      const agc = parseAgconnect();
      const missing: string[] = [];

      if (!agc) {
        missing.push("agconnect-services.json not found or invalid JSON");
      } else {
        const client = agc.client || {};
        if (!client.client_id && !HUAWEI_CLIENT_ID) missing.push("client.client_id / HUAWEI_CLIENT_ID");
        if (!client.client_secret && !HUAWEI_CLIENT_SECRET) missing.push("client.client_secret / HUAWEI_CLIENT_SECRET");
        if (!client.package_name && !HUAWEI_PACKAGE_NAME) missing.push("client.package_name / HUAWEI_PACKAGE_NAME");
        if (!client.app_id && !HUAWEI_APP_ID) missing.push("client.app_id / HUAWEI_APP_ID");
      }

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                valid: missing.length === 0,
                missing,
                agconnect_path: AGCONNECT_PATH || null,
                note: "This validation checks config completeness. It does not guarantee Huawei API acceptance without a valid AppGallery project.",
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    case "huawei_get_release_checklist": {
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                platform: "Huawei AppGallery",
                checklist: [
                  "Create or open Huawei AppGallery Connect project for the app.",
                  "Configure package name to match Android applicationId.",
                  "Upload agconnect-services.json to the app configuration or store it in the project.",
                  "Add HMS / AppGallery plugin to Android Gradle build.",
                  "Use Huawei-compatible push or fallback logic when Google Play Services are absent.",
                  "Generate a signed Android release build.",
                  "Upload APK/AAB to AppGallery Connect and complete app information.",
                  "Run release tests on a Huawei device with GMS disabled.",
                  "Submit the app for review and monitor AppGallery status.",
                ],
                notes: [
                  "If the app already uses Firebase Messaging, use a dual strategy: FCM on Google devices and HMS on Huawei devices.",
                  "The Huawei file is valid only if the AppGallery project and package name match your Android app exactly.",
                ],
              },
              null,
              2,
            ),
          },
        ],
      };
    }

    case "huawei_test_oauth": {
      const result = await testHuaweiOAuth();
      return toolJson(result);
    }

    case "huawei_get_app_info": {
      const appId = resolveAppId(args);
      if (!appId) {
        return toolJson({ error: "No appId. Pass appId or set HUAWEI_APP_ID / HUAWEI.txt App ID." });
      }
      const params = new URLSearchParams({ appId });
      if (args?.lang) params.set("lang", String(args.lang));
      if (args?.releaseType !== undefined) params.set("releaseType", String(args.releaseType));
      return toolJson(await agcRequest("GET", `publish/v2/app-info?${params}`));
    }

    case "huawei_get_release_status": {
      const appId = resolveAppId(args);
      if (!appId) {
        return toolJson({ error: "No appId. Pass appId or set HUAWEI_APP_ID / HUAWEI.txt App ID." });
      }
      const data = await agcRequest("GET", `publish/v2/app-info?appId=${appId}`);
      const info = data?.appInfo || {};
      const state = info.releaseState;
      return toolJson({
        ret: data?.ret,
        appId,
        releaseState: state,
        releaseStateLabel: state !== undefined ? RELEASE_STATE_LABELS[state] ?? `unknown(${state})` : null,
        onShelf: {
          versionNumber: info.onShelfVersionNumber ?? null,
          versionCode: info.onShelfVersionCode ?? null,
          versionId: info.onShelfVersionId ?? null,
        },
        pending: {
          versionNumber: info.versionNumber ?? null,
          versionCode: info.versionCode ?? null,
          versionId: info.versionId ?? null,
        },
        releasePhase: info.releasePhase ?? null,
        publishCountry: info.publishCountry ?? null,
        releaseTime: info.releaseTime ?? null,
        updateTime: info.updateTime ?? null,
        auditOpinion: data?.auditInfo?.auditOpinion ?? null,
      });
    }

    case "huawei_get_app_id": {
      return toolJson(
        await agcRequest(
          "GET",
          `publish/v2/appid-list?packageName=${encodeURIComponent(String(args?.packageName || ""))}`,
        ),
      );
    }

    case "huawei_get_compile_status": {
      const appId = resolveAppId(args);
      const pkgVersion = args?.pkgVersion;
      if (!appId || !pkgVersion) {
        return toolJson({ error: "appId and pkgVersion are required." });
      }
      return toolJson(
        await agcRequest(
          "GET",
          `publish/v2/aab/complile/status?appId=${appId}&pkgVersion=${encodeURIComponent(String(pkgVersion))}`,
        ),
      );
    }

    case "huawei_api_request": {
      const method = String(args?.method || "GET").toUpperCase() as "GET" | "POST" | "PUT" | "DELETE";
      const apiPath = String(args?.path || "");
      if (!apiPath) {
        return toolJson({ error: "path is required." });
      }
      return toolJson(await agcRequest(method, apiPath, args?.body));
    }

    default:
      return {
        content: [{ type: "text", text: `Unknown tool: ${String(name)}` }],
        isError: true,
      };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("✅ Huawei MCP server started");
}

main().catch((error) => {
  console.error("Huawei MCP failed to start:", error);
  process.exit(1);
});
