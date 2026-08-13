// Regenerates altstore.json - the AltStore **Classic** source manifest, so the
// app can be added to AltStore by URL once and updates itself from then on,
// with no cable and no computer.
//
// Classic rather than PAL: a PAL source points at an Alternative Distribution
// Package, which needs a paid Apple Developer account, Apple notarisation of
// every build and the EU Alternative Terms Addendum. This one points at a
// plain unsigned .ipa, which is what a free Apple ID can install.
//
//   node tools/altstore/make-source.mjs <releases.json>
//
// releases.json is the GitHub releases API payload, newest first. CI pipes
// `gh api repos/<repo>/releases --paginate` into it, so the manifest cannot
// drift from what actually exists.
//
// THE VERSION HISTORY IS THE POINT. AltStore resolves the *installed* build
// against this array, so a latest-only list lets "add source" work while every
// subsequent Update fails with the singularly unhelpful "The data couldn't be
// read because it isn't in the correct format". AltStore's own official source
// carries its full history, newest first; match that.
//
// `buildVersion` is emitted even though the official source has no such field.
// Removing it breaks installing while leaving the source displayable, because
// the install path decodes the chosen version entry in full.

import { readFileSync, writeFileSync } from 'node:fs';

const [releasesPath] = process.argv.slice(2);
if (!releasesPath) {
  console.error('usage: node tools/altstore/make-source.mjs <releases.json>');
  process.exit(1);
}

const REPO = 'doctorspider42/null-eigenvalue';
const SITE = 'https://doctorspider42.github.io/null-eigenvalue';
const IPA = 'NullEigenvalue.ipa';
const BUNDLE_ID = 'com.nulleigenvalue.nullEigenvalue';
const MIN_OS = '15.0';

const releases = JSON.parse(readFileSync(releasesPath, 'utf8'));
if (!Array.isArray(releases)) {
  console.error('releases.json must be the GitHub releases payload (an array)');
  process.exit(1);
}

// The tag is authoritative here, unlike in some other repos: CI derives the
// version from the run number and passes the same string to --build-name, to
// --build-number's source and to the tag in one job, so there is nothing for
// them to disagree about. v0.1.42 means CFBundleShortVersionString 0.1.42 and
// CFBundleVersion 42.
const parse = (tag) => {
  const m = /^v(\d+)\.(\d+)\.(\d+)$/.exec(tag);
  if (!m) return null;
  return { version: `${m[1]}.${m[2]}.${m[3]}`, build: m[3] };
};

const versions = [];
const skipped = [];
for (const r of releases) {
  if (r.draft) continue;
  const asset = (r.assets || []).find((a) => a.name === IPA);
  if (!asset) {
    skipped.push(`${r.tag_name}: no ${IPA} asset`);
    continue;
  }
  const v = parse(r.tag_name);
  if (!v) {
    skipped.push(`${r.tag_name}: not a vMAJOR.MINOR.PATCH tag`);
    continue;
  }
  versions.push({
    version: v.version,
    buildVersion: v.build,
    date: r.published_at || r.created_at, // full ISO 8601 with a timezone
    localizedDescription: (r.body || `Release ${r.tag_name}.`).trim().slice(0, 1000),
    // Each entry points at ITS OWN asset rather than at /releases/latest/,
    // which would hand every older entry the newest build.
    downloadURL: `https://github.com/${REPO}/releases/download/${r.tag_name}/${IPA}`,
    size: asset.size,
    minOSVersion: MIN_OS,
  });
}
for (const s of skipped) console.log(`skipped ${s}`);
if (versions.length === 0) {
  console.error(`no release carries a ${IPA} asset yet - nothing to advertise`);
  process.exit(1);
}

// Newest first. The API returns them that way already, but sorting means a
// hand-made release cannot land in the middle.
versions.sort((a, b) => new Date(b.date) - new Date(a.date));
const newest = versions[0];

const description = [
  'A generative drone instrument. It synthesises continuously - nothing is',
  'streamed and nothing is a loop - and it keeps playing with the screen off,',
  'with play, pause and mood change on the lock screen.',
  '',
  'Drag anywhere. Left to right is brightness, subterranean at one edge and',
  'glassy at the other; down to up is density, from a bare drone to four',
  'octaves of moving voices. Tap once for the transport and the five moods;',
  'it hides itself again after a few seconds.',
  '',
  'Fourteen voices breathe over a fixed root on periods spaced by the golden',
  'ratio, so no two are commensurable and the texture never repeats. Each one',
  'takes a new pitch while it is silent, chosen by how it sounds against',
  'whatever is currently audible - so the harmony moves without you ever',
  'hearing it change.',
].join('\n');

const source = {
  name: 'Null Eigenvalue',
  identifier: `${BUNDLE_ID}.source`,
  subtitle: 'A generative drone that runs with the screen off',
  description: 'Releases of Null Eigenvalue.',
  website: `https://github.com/${REPO}`,
  apps: [
    {
      name: 'Null Eigenvalue',
      bundleIdentifier: BUNDLE_ID,
      developerName: 'doctorspider42',
      subtitle: 'Generative drone and ambient, endlessly',
      localizedDescription: description,
      // Served from Pages beside the manifest rather than from
      // raw.githubusercontent.com: GitHub rate-limits raw, and a rate-limited
      // fetch hands AltStore an error page instead of an image.
      iconURL: `${SITE}/icon.png`,
      tintColor: '5CE0CC',
      screenshots: [],
      // Legacy mirror of the newest entry: older AltStore builds read these
      // directly instead of walking `versions`, and the official source keeps
      // them too. Here alone the /latest/ permalink is correct, because here
      // alone it always means the newest.
      version: newest.version,
      versionDate: newest.date,
      versionDescription: newest.localizedDescription,
      downloadURL: `https://github.com/${REPO}/releases/latest/download/${IPA}`,
      size: newest.size,
      minOSVersion: MIN_OS,
      versions,
      appPermissions: {
        entitlements: [],
        privacy: {},
      },
    },
  ],
  news: [],
};

// Check before writing. AltStore decodes a source with a strict Swift decoder
// and reports any shortfall as "The data couldn't be read because it isn't in
// the correct format" - on the phone, after an install attempt. Assert the
// shape here instead of discovering it there.
const problems = [];
const req = (obj, keys, where) => {
  for (const k of keys) {
    const v = obj[k];
    if (v === undefined || v === null || v === '') problems.push(`${where}: missing ${k}`);
  }
};
req(source, ['name', 'identifier', 'apps'], 'source');
for (const [i, app] of source.apps.entries()) {
  req(app, ['name', 'bundleIdentifier', 'developerName', 'localizedDescription',
            'iconURL', 'versions'], `apps[${i}]`);
  if (!Array.isArray(app.versions) || app.versions.length === 0) {
    problems.push(`apps[${i}]: versions must be a non-empty array`);
  }
  const seen = new Set();
  for (const [k, v] of (app.versions || []).entries()) {
    const at = `apps[${i}].versions[${k}]`;
    req(v, ['version', 'buildVersion', 'date', 'downloadURL', 'size'], at);
    if (typeof v.size !== 'number' || v.size <= 0) {
      problems.push(`${at}: size must be a positive number`);
    }
    if (isNaN(new Date(v.date))) problems.push(`${at}: date "${v.date}" is unparseable`);
    if (!String(v.downloadURL).includes(`/${IPA}`)) {
      problems.push(`${at}: downloadURL does not point at ${IPA}`);
    }
    if (seen.has(v.version)) problems.push(`apps[${i}]: duplicate version ${v.version}`);
    seen.add(v.version);
  }
  if (app.version !== app.versions?.[0]?.version) {
    problems.push(
      `apps[${i}]: legacy version ${app.version} disagrees with versions[0] ` +
      `${app.versions?.[0]?.version}`);
  }
}
if (problems.length) {
  console.error('altstore.json would be invalid:\n  ' + problems.join('\n  '));
  process.exit(1);
}

writeFileSync(new URL('../../altstore.json', import.meta.url),
              JSON.stringify(source, null, 2) + '\n');
console.log(`altstore.json: ${versions.length} version(s), newest ${newest.version}`);
for (const v of versions) {
  console.log(`  ${v.version.padEnd(10)} ${v.date}  ${v.size} bytes`);
}
