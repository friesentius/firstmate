const dom = require("node:fs").readFileSync(process.argv[2], "utf8");
const messages = dom.match(/<div id="messages">([\s\S]*?)<\/main>/)?.[1];
const tree = dom.match(/<div[^>]*id="tree-container"[^>]*>([\s\S]*?)<div[^>]*id="tree-status"/)?.[1];
if (!messages || !tree) process.exit(1);
if (!/<div class="user-message"[^>]*>[\s\S]*Show a deterministic tool example\./.test(messages)) process.exit(1);
if (!/<div class="assistant-message"[^>]*>[\s\S]*The deterministic tool example is complete\./.test(messages)) process.exit(1);
// Pi 0.99.x keeps display:false custom messages in #messages as hook-message-hidden
// entries behind its own show-hidden toggle; older Pi omitted them. Either is within the
// boundary, but no custom message may render visibly by default.
const hookTag = /<div class="(hook-message(?:\s[^"]*)?)"[^>]*>/g;
let visibleMessages = "";
let cursor = 0;
let hiddenCount = 0;
for (const tag of messages.matchAll(hookTag)) {
  if (tag.index < cursor) continue;
  if (!tag[1].split(/\s+/).includes("hook-message-hidden")) process.exit(1);
  hiddenCount++;
  visibleMessages += messages.slice(cursor, tag.index);
  const divs = /<div\b|<\/div>/g;
  divs.lastIndex = tag.index + tag[0].length;
  let depth = 1;
  let match;
  while (depth > 0 && (match = divs.exec(messages))) depth += match[0] === "</div>" ? -1 : 1;
  if (depth > 0) process.exit(1);
  cursor = divs.lastIndex;
}
visibleMessages += messages.slice(cursor);
if (visibleMessages.includes("[firstmate-synthetic-input]")) process.exit(1);
if (hiddenCount > 0) {
  if (/<body[^>]*class="[^"]*\bshow-hidden-messages\b/.test(dom)) process.exit(1);
  if (!/body:not\(\.show-hidden-messages\)\s+\.hook-message-hidden\s*\{\s*display:\s*none;?\s*\}/.test(dom)) process.exit(1);
}
if (!tree.includes("firstmate-synthetic-input") || !tree.includes("/tmp/probe.status")) process.exit(1);
