//
//  BatSignBridge.cpp
//  BatSign
//
//  Replicates the zsign CLI's zip signing path with structured parameters,
//  without pulling in its getopt-based main(). Engine: vendored zsign (MIT).
//

#include "BatSignBridge.h"

// Include via the same search-path spellings the engine uses, so that
// #pragma once sees one canonical path per header.
#include "common.h"
#include "archive.h"
#include "util.h"
#include "macho.h"
#include "openssl.h"
#include "bundle.h"

#include <string>
#include <vector>
#include <cstdlib>

using namespace std;

// ---------------------------------------------------------------------------
// Log hook plumbing (consumed by the patched src/common/log.cpp)
// ---------------------------------------------------------------------------

static batsign_log_cb g_log_cb = NULL;
static void* g_log_ctx = NULL;

// Single dispatch point: called by the patched src/common/log.cpp.
// The host's callback always receives (line, context) correctly typed.
extern "C" void batsign_dispatch_log(const char* szLog)
{
	if (NULL != g_log_cb && NULL != szLog) {
		g_log_cb(szLog, g_log_ctx);
	}
}

extern "C" void batsign_set_log_callback(batsign_log_cb cb, void* context)
{
	g_log_cb = cb;
	g_log_ctx = context;
}

static void bridge_log(const char* szLog)
{
	if (NULL != g_log_cb && NULL != szLog) {
		g_log_cb(szLog, g_log_ctx);
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static string safe_str(const char* s)
{
	return (NULL == s) ? string() : string(s);
}

// ---------------------------------------------------------------------------
// Sign
// ---------------------------------------------------------------------------

extern "C" int batsign_sign_ipa(const char* in_ipa,
								const char* out_ipa,
								const char* cert_p12,
								const char* prov_profile,
								const char* password,
								const char* entitlements_path,
								const char* bundle_id,
								const char* bundle_version,
								const char* display_name,
								const char* min_version,
								const char* const* dylibs, int dylib_count,
								const char* const* remove_dylib_names, int remove_dylib_count,
								int adhoc,
								int weak_inject,
								int remove_extensions,
								int remove_watch,
								int remove_provision,
								int remove_supported_devices,
								int enable_documents,
								int zip_level,
								const char* temp_folder,
								const char* icon_png,
								const char* info_plist_overrides_file)
{
	string strIn = safe_str(in_ipa);
	string strOut = safe_str(out_ipa);
	string strTemp = safe_str(temp_folder);

	if (strIn.empty() || strOut.empty()) {
		bridge_log("!!! BatSign: input or output path missing.\n");
		return BATSIGN_ERR_ARGS;
	}
	if (!ZFile::IsFileExists(strIn.c_str())) {
		bridge_log("!!! BatSign: input file does not exist.\n");
		return BATSIGN_ERR_ARGS;
	}
	if (!ZFile::IsZipFile(strIn.c_str())) {
		bridge_log("!!! BatSign: input is not a zip/ipa archive.\n");
		return BATSIGN_ERR_ARGS;
	}
	if (strTemp.empty() || !ZFile::IsFolder(strTemp.c_str())) {
		bridge_log("!!! BatSign: temp folder missing.\n");
		return BATSIGN_ERR_ARGS;
	}
	if (zip_level < 0 || zip_level > 9) {
		zip_level = 9;
	}

	// Validate dylibs up front (same as the CLI).
	vector<string> arrDylibFiles;
	for (int i = 0; i < dylib_count; ++i) {
		string strDylib = safe_str(dylibs[i]);
		if (strDylib.empty()) {
			continue;
		}
		if (!ZFile::IsFileExists(strDylib.c_str())) {
			bridge_log("!!! BatSign: dylib file not found.\n");
			return BATSIGN_ERR_ARGS;
		}
		ZMachO dylibMachO;
		if (!dylibMachO.Init(strDylib.c_str())) {
			bridge_log("!!! BatSign: invalid dylib (not a Mach-O).\n");
			return BATSIGN_ERR_ARGS;
		}
		arrDylibFiles.push_back(ZFile::GetFullPath(strDylib.c_str()));
	}

	vector<string> arrRemoveDylibNames;
	for (int i = 0; i < remove_dylib_count; ++i) {
		string strName = safe_str(remove_dylib_names[i]);
		if (!strName.empty()) {
			arrRemoveDylibNames.push_back(strName);
		}
	}

	const bool bAdhoc = (0 != adhoc);
	const bool bWeakInject = (0 != weak_inject);
	const bool bRemoveProvision = (0 != remove_provision);
	const bool bSHA256Only = true;

	// 1. Init signing asset (parses p12 + provision profile).
	// zsign loads identities through the pkey slot (-k), which accepts a p12;
	// the cert slot is only for separate PEM certificates.
	ZSignAsset zsa;
	if (!zsa.Init(safe_str(cert_p12),
				  safe_str(cert_p12),
				  safe_str(prov_profile),
				  safe_str(entitlements_path),
				  safe_str(password),
				  bAdhoc,
				  bSHA256Only,
				  false)) {
		bridge_log("!!! BatSign: failed to initialize certificate/profile (wrong password or invalid files?).\n");
		return BATSIGN_ERR_INIT;
	}

	// 2. Extract the ipa into a unique temp folder.
	string strFolder = ZFile::GetRealPathV("%s/batsign_work_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
	ZFile::CreateFolder(strFolder.c_str());
	bridge_log(">>> Unzipping app payload ...\n");
	if (!Zip::Extract(strIn.c_str(), strFolder.c_str())) {
		bridge_log("!!! BatSign: unzip failed.\n");
		return BATSIGN_ERR_EXTRACT;
	}

	// 2b. Merge Info.plist overrides before signing.
	string strPlistOverridesFile = safe_str(info_plist_overrides_file);
	if (!strPlistOverridesFile.empty()) {
		string strPatch;
		if (!ZFile::ReadFile(strPlistOverridesFile.c_str(), strPatch)) {
			bridge_log("!!! BatSign: Info.plist overrides file unreadable.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_ARGS;
		}
		jvalue jvPatch;
		if (!jvPatch.read_plist(strPatch)) {
			bridge_log("!!! BatSign: Info.plist overrides are not a valid plist.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_ARGS;
		}

		string strInfoPlist;
		// EnumFolder semantics: filter returning true SKIPS an entry,
		// callback returning true STOPS the walk.
		ZFile::EnumFolder(strFolder.c_str(), true,
			[](bool, const string&) { return false; },
			[&strInfoPlist](bool bFolder, const string& strPath) -> bool {
				if (bFolder || !strInfoPlist.empty()) {
					return false; // keep walking
				}
				const string kSuffix = ".app/Info.plist";
				const string kPayload = "/Payload/";
				if (strPath.size() <= kSuffix.size()) {
					return false;
				}
				if (0 != strPath.compare(strPath.size() - kSuffix.size(), kSuffix.size(), kSuffix)) {
					return false;
				}
				size_t payloadPos = strPath.find(kPayload);
				if (string::npos == payloadPos) {
					return false;
				}
				// Only the top-level app bundle: the bundle directory itself
				// (between Payload/ and ".app") must not contain a slash.
				size_t bundleStart = payloadPos + kPayload.size();
				size_t appStart = strPath.size() - kSuffix.size();
				if (bundleStart >= appStart) {
					return false;
				}
				string dirname = strPath.substr(bundleStart, appStart - bundleStart);
				if (dirname.empty() || string::npos != dirname.find('/')) {
					return false;
				}
				strInfoPlist = strPath;
				return true; // found it — stop the walk
			});

		if (strInfoPlist.empty()) {
			bridge_log("!!! BatSign: no top-level Payload/<App>.app/Info.plist found for overrides.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_PAYLOAD;
		}

		string strInfo;
		if (!ZFile::ReadFile(strInfoPlist.c_str(), strInfo)) {
			bridge_log("!!! BatSign: Info.plist unreadable.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_EXTRACT;
		}
		jvalue jvInfo;
		if (!jvInfo.read_plist(strInfo)) {
			bridge_log("!!! BatSign: Info.plist could not be parsed.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_EXTRACT;
		}
		vector<string> arrKeys;
		jvPatch.get_keys(arrKeys);
		for (const string& strKey : arrKeys) {
			jvInfo[strKey] = jvPatch[strKey];
		}
		if (!jvInfo.style_write_plist_to_file(strInfoPlist.c_str())) {
			bridge_log("!!! BatSign: failed to write patched Info.plist.\n");
			ZFile::RemoveFolder(strFolder.c_str());
			return BATSIGN_ERR_EXTRACT;
		}
		bridge_log(">>> Info.plist overrides applied.\n");
	}

	// 3. Sign (applies metadata changes, injection, removals, then signs all nested code).
	ZBundle bundle;
	bundle.m_bEnableDocuments = (0 != enable_documents);
	bundle.m_strMinVersion = safe_str(min_version);
	bundle.m_strIconFile = safe_str(icon_png);
	bundle.m_bRemoveExtensions = (0 != remove_extensions);
	bundle.m_bRemoveWatchApp = (0 != remove_watch);
	bundle.m_bRemoveUISupportedDevices = (0 != remove_supported_devices);

	bool bRet = bundle.SignFolder(&zsa,
								  strFolder,
								  safe_str(bundle_id),
								  safe_str(bundle_version),
								  safe_str(display_name),
								  arrDylibFiles,
								  arrRemoveDylibNames,
								  true /*bForce*/,
								  bWeakInject,
								  false /*bEnableCache*/,
								  bRemoveProvision);

	if (!bRet) {
		ZFile::RemoveFolder(strFolder.c_str());
		bridge_log("!!! BatSign: signing failed.\n");
		return BATSIGN_ERR_SIGN;
	}

	// 4. Archive back into an ipa.
	size_t pos = bundle.m_strAppFolder.rfind("Payload");
	if (string::npos == pos || 0 == pos) {
		ZFile::RemoveFolder(strFolder.c_str());
		bridge_log("!!! BatSign: can't find Payload directory.\n");
		return BATSIGN_ERR_PAYLOAD;
	}

	string strBaseFolder = bundle.m_strAppFolder.substr(0, pos - 1);
	bridge_log(">>> Archiving signed ipa ...\n");
	if (!Zip::Archive(strBaseFolder.c_str(), strOut.c_str(), zip_level)) {
		ZFile::RemoveFolder(strFolder.c_str());
		bridge_log("!!! BatSign: archive failed.\n");
		return BATSIGN_ERR_ARCHIVE;
	}

	ZFile::RemoveFolder(strFolder.c_str());
	bridge_log(">>> Done. Signed ipa written successfully.\n");
	return BATSIGN_OK;
}
