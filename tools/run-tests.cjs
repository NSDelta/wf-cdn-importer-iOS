#!/usr/bin/env node
"use strict"

// 本仓库的最小测试运行器：把 tools/*.test.cjs 逐个用 node 跑一遍。
// 每个测试文件自带断言（node:assert + node:test），不依赖任何外部框架与 npm 依赖。
//
//   node tools/run-tests.cjs                    # 跑全部
//   node tools/run-tests.cjs --filter inject    # 只跑文件名含 inject 的
//   node tools/run-tests.cjs --list             # 只列出会跑哪些文件
//
// 退出码：0 = 全过（允许 skip），1 = 有失败，2 = 用法/环境错误。

const fs = require("node:fs")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

const ROOT = path.resolve(__dirname, "..")
const TESTS_DIR = __dirname
const TIMEOUT_MS = 5 * 60 * 1000
const FAILURE_TAIL_LINES = 60

function parseArguments(argv) {
    let filter = null
    let list = false

    for (let index = 0; index < argv.length; index++) {
        const argument = argv[index]
        if (argument === "--filter") {
            const value = argv[++index]
            if (!value || value.startsWith("--")) throw new Error("--filter 需要一个子串")
            filter = value
            continue
        }
        if (argument === "--list") {
            list = true
            continue
        }
        throw new Error(`未知参数：${argument}`)
    }

    return { filter, list }
}

function testFiles(filter) {
    return fs.readdirSync(TESTS_DIR)
        .filter(name => name.endsWith(".test.cjs"))
        .filter(name => filter === null || name.includes(filter))
        .sort()
}

function skippedCases(output) {
    const match = output.match(/^\s*#\s*skipped\s+(\d+)\s*$/m)
    return match ? Number(match[1]) : 0
}

function runFile(file) {
    const startedAt = process.hrtime.bigint()
    const result = spawnSync(process.execPath, [path.join(TESTS_DIR, file)], {
        cwd: ROOT,
        encoding: "utf8",
        timeout: TIMEOUT_MS,
        maxBuffer: 32 * 1024 * 1024,
    })
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`

    let status = "passed"
    if (result.error) status = "failed"
    else if (result.status !== 0) status = "failed"

    return {
        durationMs,
        file,
        output,
        skipped: skippedCases(output),
        status,
        error: result.error ?? null,
    }
}

function formatDuration(durationMs) {
    return durationMs < 1000
        ? `${Math.round(durationMs)}ms`
        : `${(durationMs / 1000).toFixed(2)}s`
}

function tail(output) {
    const lines = output.trimEnd().split(/\r?\n/)
    return lines.slice(-FAILURE_TAIL_LINES).join("\n")
}

function main(argv) {
    let parsed
    try {
        parsed = parseArguments(argv)
    } catch (error) {
        process.stderr.write(`${error.message}\n`)
        return 2
    }

    const files = testFiles(parsed.filter)
    if (files.length === 0) {
        process.stderr.write("没有匹配的测试文件（tools/*.test.cjs）\n")
        return 2
    }
    if (parsed.list) {
        for (const file of files) process.stdout.write(`${file}\n`)
        return 0
    }

    const startedAll = process.hrtime.bigint()
    let passed = 0
    let failed = 0
    let skipped = 0

    for (const file of files) {
        const result = runFile(file)
        const label = result.status.toUpperCase()
        process.stdout.write(`[${label}] ${result.file} (${formatDuration(result.durationMs)})\n`)
        if (result.status === "passed") {
            passed++
            skipped += result.skipped
        } else {
            failed++
            if (result.error) process.stdout.write(`${result.error.message}\n`)
            if (result.output.trim()) process.stdout.write(`${tail(result.output)}\n`)
        }
    }

    const totalMs = Number(process.hrtime.bigint() - startedAll) / 1e6
    process.stdout.write(
        `Summary: passed=${passed} failed=${failed} skipped=${skipped} total=${formatDuration(totalMs)}\n`,
    )
    return failed > 0 ? 1 : 0
}

if (require.main === module) {
    try {
        process.exitCode = main(process.argv.slice(2))
    } catch (error) {
        process.stderr.write(`${error.stack || error.message}\n`)
        process.exitCode = 2
    }
}

module.exports = { main, parseArguments, skippedCases, testFiles }
