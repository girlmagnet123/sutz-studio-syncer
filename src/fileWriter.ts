import fs from "node:fs";
import path from "node:path";
import type { StudioInstanceRecord } from "./protocol.js";

export interface FileWriterOptions {
  rootDir: string;
}

export class FileWriter {
  private readonly rootDir: string;
  private readonly guidToPath = new Map<string, string>();

  public constructor(options: FileWriterOptions) {
    this.rootDir = path.resolve(options.rootDir);
  }

  public ensureRoot(): void {
    fs.mkdirSync(this.rootDir, { recursive: true });
  }

  public writeSnapshot(instances: StudioInstanceRecord[]): number {
    this.ensureRoot();
    this.guidToPath.clear();

    let written = 0;
    for (const instance of instances) {
      if (this.writeScript(instance)) {
        written += 1;
      }
    }

    return written;
  }

  public writeScript(instance: StudioInstanceRecord): boolean {
    if (!this.isScript(instance) || typeof instance.source !== "string") {
      return false;
    }

    this.ensureRoot();

    const filePath = this.getFilePath(instance);
    const previousPath = this.guidToPath.get(instance.guid);

    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, instance.source, "utf8");

    if (previousPath && previousPath !== filePath && fs.existsSync(previousPath)) {
      fs.unlinkSync(previousPath);
      this.removeEmptyParents(path.dirname(previousPath));
    }

    this.guidToPath.set(instance.guid, filePath);
    return true;
  }

  public remove(guid: string): boolean {
    const filePath = this.guidToPath.get(guid);
    if (!filePath) {
      return false;
    }

    this.guidToPath.delete(guid);

    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      this.removeEmptyParents(path.dirname(filePath));
    }

    return true;
  }

  public getRootDir(): string {
    return this.rootDir;
  }

  private getFilePath(instance: StudioInstanceRecord): string {
    const parentSegments = instance.path.slice(0, -1).map((segment) => {
      return this.sanitizeSegment(segment);
    });

    return path.join(this.rootDir, ...parentSegments, this.getFileName(instance));
  }

  private getFileName(instance: StudioInstanceRecord): string {
    const baseName = this.sanitizeSegment(instance.name);

    if (instance.className === "Script") {
      return `${baseName}.server.luau`;
    }

    if (instance.className === "LocalScript") {
      return `${baseName}.client.luau`;
    }

    return `${baseName}.luau`;
  }

  private sanitizeSegment(segment: string): string {
    return segment.replace(/[<>:"/\\|?*]/g, "_").trim() || "unnamed";
  }

  private isScript(instance: StudioInstanceRecord): boolean {
    return (
      instance.className === "Script" ||
      instance.className === "LocalScript" ||
      instance.className === "ModuleScript"
    );
  }

  private removeEmptyParents(startDir: string): void {
    let current = path.resolve(startDir);

    while (current.startsWith(this.rootDir) && current !== this.rootDir) {
      if (!fs.existsSync(current)) {
        current = path.dirname(current);
        continue;
      }

      if (fs.readdirSync(current).length > 0) {
        return;
      }

      fs.rmdirSync(current);
      current = path.dirname(current);
    }
  }
}
