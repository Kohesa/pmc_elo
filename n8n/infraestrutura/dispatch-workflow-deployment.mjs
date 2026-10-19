import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const webhookUrl = process.env.N8N_DEPLOYMENT_WEBHOOK_URL;
const deploymentSecret = process.env.N8N_DEPLOYMENT_SECRET;
const workflowsDir = process.env.N8N_WORKFLOWS_DIR;
const refName = process.env.GITHUB_REF_NAME || "";
const repository = process.env.GITHUB_REPOSITORY || "";
const sha = process.env.GITHUB_SHA || "";
const beforeSha = process.env.GITHUB_BEFORE_SHA || "";
const dryRun = process.env.N8N_DEPLOYMENT_DRY_RUN === "true";
const ignoredWorkflowDirs = new Set(["Homolog", "Produção", "Producao"]);

if (!webhookUrl && !dryRun) {
  throw new Error("N8N_DEPLOYMENT_WEBHOOK_URL is required");
}

if (!deploymentSecret && !dryRun) {
  throw new Error("N8N_DEPLOYMENT_SECRET is required");
}

if (!workflowsDir) {
  throw new Error("N8N_WORKFLOWS_DIR is required");
}

if (!fs.existsSync(workflowsDir)) {
  throw new Error(`Workflow directory not found: ${workflowsDir}`);
}

function getJsonFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      if (ignoredWorkflowDirs.has(entry.name)) {
        return [];
      }

      return getJsonFiles(fullPath);
    }

    return entry.isFile() && entry.name.endsWith(".json") ? [fullPath] : [];
  });
}

function normalizePath(file) {
  return file.replaceAll("\\", "/");
}

function isIgnoredWorkflowPath(file) {
  return normalizePath(file)
    .split("/")
    .some((part) => ignoredWorkflowDirs.has(part));
}

function isZeroSha(value) {
  return /^0+$/.test(value || "");
}

function getChangedJsonFiles() {
  if (!beforeSha || !sha || isZeroSha(beforeSha)) {
    return getJsonFiles(workflowsDir);
  }

  const output = execFileSync(
    "git",
    [
      "diff",
      "-z",
      "--name-only",
      "--diff-filter=ACMRT",
      beforeSha,
      sha,
      "--",
      workflowsDir,
    ],
    { encoding: "utf8" },
  );

  return output
    .split("\0")
    .map((file) => file.trim())
    .filter((file) => file.endsWith(".json"))
    .filter((file) => !isIgnoredWorkflowPath(file))
    .filter((file) => fs.existsSync(file));
}

const changedFiles = getChangedJsonFiles();

const workflows = changedFiles.map((file) => {
  const workflow = JSON.parse(fs.readFileSync(file, "utf8"));

  if (!workflow.name || !Array.isArray(workflow.nodes) || !workflow.connections) {
    throw new Error(`Invalid n8n workflow JSON: ${file}`);
  }

  return {
    file: normalizePath(file),
    workflow,
  };
});

if (workflows.length === 0) {
  console.log(`No changed workflow JSON files found in ${workflowsDir}`);
  process.exit(0);
}

if (dryRun) {
  console.log(
    JSON.stringify(
      {
        ok: true,
        dryRun: true,
        workflowsDir,
        workflows: workflows.map((entry) => ({
          file: entry.file,
          name: entry.workflow.name,
        })),
      },
      null,
      2,
    ),
  );
  process.exit(0);
}

const response = await fetch(webhookUrl, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Deployment-Secret": deploymentSecret,
  },
  body: JSON.stringify({
    environment: refName === "master" ? "production" : "homolog",
    ref: refName,
    repository,
    sha,
    workflowsDir,
    workflows,
  }),
});

const responseText = await response.text();

if (!response.ok) {
  throw new Error(`n8n deployment webhook failed: ${response.status} ${responseText}`);
}

console.log(responseText);
