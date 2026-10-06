#!/usr/bin/env python3

# Cimian Catalog Promoter
# Adapted from munki-promoter by Jacob Burley (j@jc0b.computer),
# Kai (https://github.com/kaiobendrauf), and
# Rod Christiansen (https://github.com/rodchristiansen)
#
# Promotes Cimian pkgsinfo through Development -> Testing -> Staging -> Production

import datetime
import logging
import os
import sys
import optparse
import re
import yaml

DEFAULT_CONFIG = {
	"promotions": {
		"testing to staging": {
			"promote_from": ["Development", "Testing"],
			"promote_to": ["Development", "Testing", "Staging"],
			"days_in_catalog": 1},
		"staging to production": {
			"promote_from": ["Development", "Testing", "Staging"],
			"promote_to": ["Development", "Testing", "Staging", "Production"],
			"days_in_catalog": 1}},
	"default_days_in_catalog": 1}

CONFIG_FILE = "promoter.yml"
PKGSINFO_PATH = "deployment/pkgsinfo/apps"

EVAL_TIME = None  # Set via --as-of to evaluate eligibility at a future time

# Only pkgsinfo imported by autopkg are auto-promoted through the catalog
# stages. Human-authored pkgsinfo (internal prefs, hand-imported apps) carry a
# different _metadata.created_by and must be promoted by hand -- otherwise an
# internal package silently rides the stages straight into Production.
AUTOPKG_IDENTITY = "autopkg"


def is_autopkg_created(item):
	"""True only when this pkgsinfo was originally imported by autopkg."""
	metadata = item.get("_metadata") or {}
	return metadata.get("created_by") == AUTOPKG_IDENTITY

# ----------------------------------------
# 			File I/O helpers (YAML)
# ----------------------------------------

def _normalize_datetime(value):
	"""Convert ISO date strings to datetime objects for consistent comparison."""
	if isinstance(value, datetime.datetime):
		# PyYAML returns tz-aware datetimes for unquoted ISO values like
		# `creation_date: 2026-04-22T17:51:22Z`. The rest of this script
		# uses naive UTC, so strip the tzinfo here to keep comparisons safe.
		if value.tzinfo is not None:
			value = value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
		return value
	if isinstance(value, datetime.date):
		return datetime.datetime(value.year, value.month, value.day)
	if isinstance(value, str):
		for fmt in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d'):
			try:
				return datetime.datetime.strptime(value, fmt)
			except ValueError:
				continue
	return None


def _normalize_metadata_dates(data):
	"""Ensure _metadata date fields are datetime objects after loading."""
	if "_metadata" in data and isinstance(data["_metadata"], dict):
		for key in ("creation_date", "cimian-promoter_edit_date"):
			if key in data["_metadata"]:
				dt = _normalize_datetime(data["_metadata"][key])
				if dt is not None:
					data["_metadata"][key] = dt
	return data


def load_pkginfo(filepath):
	"""Load a pkgsinfo YAML file and return a dict."""
	with open(filepath, "r", encoding="utf-8") as fp:
		data = yaml.safe_load(fp)
		if not isinstance(data, dict):
			raise ValueError(f"YAML file {filepath} did not parse to a dict")
		return _normalize_metadata_dates(data)


def _save_yaml_pkginfo(filepath, data):
	"""Surgically update catalogs and _metadata in a YAML file, preserving all other content."""
	with open(filepath, "r", encoding="utf-8") as fp:
		content = fp.read()

	# Update catalogs section
	catalogs = data.get('catalogs', [])
	new_catalogs = 'catalogs:\n' + ''.join(f'- {c}\n' for c in catalogs)
	content = re.sub(
		r'^catalogs:\n(?:- .+\n)+',
		new_catalogs,
		content,
		count=1,
		flags=re.MULTILINE
	)

	# Update cimian-promoter_edit_date in _metadata
	metadata = data.get('_metadata', {})
	edit_date = metadata.get('cimian-promoter_edit_date')
	if edit_date:
		if isinstance(edit_date, datetime.datetime):
			date_str = f"'{edit_date.strftime('%Y-%m-%dT%H:%M:%SZ')}'"
		else:
			date_str = f"'{edit_date}'"
		edit_line = f'  cimian-promoter_edit_date: {date_str}\n'

		if re.search(r'^_metadata:', content, re.MULTILINE):
			# _metadata exists -- update or append the edit_date key
			if re.search(r'^\s+cimian-promoter_edit_date:', content, re.MULTILINE):
				content = re.sub(
					r'^(\s+cimian-promoter_edit_date:).*\n',
					edit_line,
					content,
					count=1,
					flags=re.MULTILINE
				)
			else:
				# Append edit_date after the _metadata: line
				content = re.sub(
					r'^(_metadata:\n)',
					r'\g<1>' + edit_line,
					content,
					count=1,
					flags=re.MULTILINE
				)
		else:
			# No _metadata section -- append one
			if not content.endswith('\n'):
				content += '\n'
			content += f'_metadata:\n{edit_line}'

	with open(filepath, "w", encoding="utf-8") as fp:
		fp.write(content)


def save_pkginfo(filepath, data):
	"""Write a pkgsinfo dict back to disk."""
	_save_yaml_pkginfo(filepath, data)

_BOOLMAP = {
	'y': True, 'yes': True, 't': True, 'true': True, 'on': True, '1': True,
	'n': False, 'no': False, 'f': False, 'false': False, 'off': False, '0': False
}

# ----------------------------------------
# 				Strings
# ----------------------------------------

def and_str(l):
	if len(l) == 1:
		return l[0]
	result = ""
	for i, s in enumerate(l):
		result += s
		if i == len(l) - 2:
			result += " and "
		elif i < len(l) - 2:
			result += ", "
	return result

def white_space_pad_strings(l):
	maxlen = len(max(l, key=len))
	return [s + (' ' * (maxlen - len(s))) for s in l]

def describe_promotion(promotion, promote_to, names, versions, custom_item_descriptions):
	result = "\n------------------------------------------------------------------------------------\n"
	result += f'                        Applying promotion "{promotion}"\n'
	result += f"   Promoting the catalogs of the following pkgsinfo files to {promote_to}\n"
	result += "------------------------------------------------------------------------------------\n"
	if len(names) > 0:
		names = white_space_pad_strings(names)
		for i, name in enumerate(names):
			result += f"{name} - {versions[i]}\n"
	if len(custom_item_descriptions['names']) > 0:
		custom_names = white_space_pad_strings(custom_item_descriptions['names'])
		custom_versions = white_space_pad_strings(custom_item_descriptions['versions'])
		custom_promote_tos = custom_item_descriptions['promote_tos']
		result += "The following pkgsinfo files are custom items that impact which catalog they will be promoted to:\n"
		for i, name in enumerate(custom_names):
			result += f"{name} - {custom_versions[i]} - will be promoted to {and_str(custom_promote_tos[i])} \n"
	return result

# ----------------------------------------
# 			Configurations
# ----------------------------------------
def get_config(config_path, is_config_specified) -> dict:
	if not os.path.exists(config_path):
		if is_config_specified:
			logging.error(f"Configuration file {config_path} is not present.")
			sys.exit(1)
		else:
			logging.warning("No configuration file is present. Will continue with default settings.")
			return DEFAULT_CONFIG
	if not os.access(config_path, os.R_OK):
		logging.error(f"You don't have access to {config_path}")
		sys.exit(1)
	with open(config_path, "r") as config_yaml:
		logging.info(f"Loading {config_path} ...")
		try:
			result = yaml.safe_load(config_yaml)
			logging.info(f"Successfully loaded {config_path}!")
			return result
		except yaml.YAMLError:
			logging.error(f"Unable to load {config_path}")
			sys.exit(1)

def print_promotions(config, config_path):
	promotion_strings = []
	from_strings = []
	to_strings = []
	error_promotions = []
	error_descriptions = []
	promotions_found = False
	if config and "promotions" in config:
		promotions = config["promotions"]
		for promotion in promotions:
			if is_valid_promotion(promotion, promotions):
				to_str = and_str(promotions[promotion]["promote_to"])
				from_str = promotion
				if "promote_from" in promotions[promotion]:
					if promotions[promotion]["promote_from"] and type(promotions[promotion]["promote_from"]) == list and len(promotions[promotion]["promote_from"]) > 0:
						from_str = and_str(promotions[promotion]["promote_from"])
				promotion_strings.append(promotion)
				from_strings.append(from_str)
				to_strings.append(to_str)
				promotions_found = True
			else:
				error_promotions.append(promotion)
				error_descriptions.append(f"improperly defined! Which catalog(s) promotion \"{promotion}\" promotes to is undefined. Promotions can be configured in {config_path}.")
	if promotions_found:
		promotion_strings = promotion_strings + error_promotions
		promotion_strings = white_space_pad_strings(promotion_strings)
		from_strings = white_space_pad_strings(from_strings)
		len_from = len(from_strings)
		for i, from_str in enumerate(from_strings):
			print(promotion_strings[i] + " : promotes from " + from_str + " to " + to_strings[i])
		for i, error_string in enumerate(error_descriptions):
			print(promotion_strings[i + len_from] + " : " + error_string)
	else:
		print(f"No promotions are currently defined. Promotions can be configured in {config_path}.")

def does_promotion_exist(promotion, promotions):
	return promotions and type(promotions) == dict and promotion in promotions

def is_valid_promotion(promotion, promotions):
	if type(promotions[promotion]) == dict:
		if "promote_to" in promotions[promotion] and type(promotions[promotion]["promote_to"]) == list:
			if len(promotions[promotion]["promote_to"]) > 0:
				return True
	return False

def get_promotion_info(promotion, promotions, config, config_path):
	if is_valid_promotion(promotion, promotions):
		promote_to = promotions[promotion]["promote_to"]
		promote_from = [promotion]
		if "promote_from" in promotions[promotion] and type(promotions[promotion]["promote_from"]) == list and len(promotions[promotion]["promote_to"]) > 0:
			promote_from = promotions[promotion]["promote_from"]
		custom_items = dict()
		if "custom_items" in promotions[promotion] and type(promotions[promotion]["custom_items"]) == dict:
			custom_items = promotions[promotion]["custom_items"]
		if "days_in_catalog" in promotions[promotion]:
			days = promotions[promotion]["days_in_catalog"]
		elif "default_days_in_catalog" in config:
			days = config["default_days_in_catalog"]
		else:
			logging.error(f'Promotion "{promotion}" improperly defined! `days_in_catalog` is undefined and no `default_days_in_catalog` has been defined. Promotions can be configured in {config_path}. Use --list to see valid catalogs to promote.')
			sys.exit(1)
		return promote_to, promote_from, days, custom_items
	else:
		logging.error(f'Promotion "{promotion}" improperly defined! Which catalog(s) promotion "{promotion}" promotes to is undefined. Promotions can be configured in {config_path}. Use --list to see valid catalogs to promote.')
		sys.exit(1)

def check_selection_specified_correctly(config, config_path):
	if config and "selection" in config:
		if "type" in config["selection"]:
			if config["selection"]["type"] == "inclusion":
				if "items" not in config["selection"] or type(config["selection"]["items"]) != list or len(config["selection"]["items"]) < 1:
					logging.warning(f"Selection type set to inclusion but no list of items defined in {config_path}. No items will be considered.")
			elif config["selection"]["type"] == "exclusion":
				if "items" not in config["selection"] or type(config["selection"]["items"]) != list or len(config["selection"]["items"]) < 1:
					logging.warning(f"Selection type set to exclusion but no list of items defined in {config_path}. All items will be considered.")
			elif config["selection"]["type"] != "all":
				logging.error(f'Selection type set incorrectly in {config_path}. Selection type must be "inclusion", "exclusion", or "all", but was set to {config["selection"]["type"]}.')
				sys.exit(1)
		else:
			logging.warning(f"Selection key found in {config_path}, but no selection type found. All items will be considered.")

# ----------------------------------------
#			Markdown change log
# ----------------------------------------
def write_md_file(md_file, md):
	try:
		with open(md_file, "w") as f:
			f.write(md)
		logging.info("Markdown file successfully updated.")
	except Exception:
		logging.error(f"Unable to write to {md_file}")
		sys.exit(1)


def md_description(promotion, promote_to, names, versions, custom_item_descriptions):
	result = f'Applied promotion "{promotion}".\n'
	if len(names) > 0:
		if len(promote_to) > 1:
			result += f"The following items have been automatically promoted to Cimian {and_str(promote_to)} catalogs:\n"
		else:
			result += f"The following items have been automatically promoted to Cimian {promote_to[0]} catalog:\n"
		for i, name in enumerate(names):
			result += f"- {name}: {versions[i]}\n"

	custom_names = custom_item_descriptions['names']
	custom_versions = custom_item_descriptions['versions']
	custom_promote_tos = custom_item_descriptions['promote_tos']
	if len(custom_names) > 0:
		result += "The following custom items have been automatically promoted:\n"
		for i, name in enumerate(custom_names):
			if len(custom_promote_tos[i]) > 1:
				result += f"- {name}: {custom_versions[i]} (promoted to Cimian {and_str(custom_promote_tos[i])} catalogs)\n"
			else:
				result += f"- {name}: {custom_versions[i]} (promoted to Cimian {and_str(custom_promote_tos[i])} catalog)\n"
	result += "\n"
	return result

# ----------------------------------------
#					Cimian
# ----------------------------------------
def get_pkgsinfo_paths(pkgsinfo_path):
	result = []
	if not os.path.exists(pkgsinfo_path):
		logging.error(f"Path to pkgsinfo directory {pkgsinfo_path} does not exist.")
		sys.exit(1)
	if not os.access(pkgsinfo_path, os.W_OK):
		logging.error(f"You don't have access to {pkgsinfo_path}")
		sys.exit(1)
	managed_path = os.path.abspath(os.path.join(pkgsinfo_path, "managed"))
	for root, dirs, files in os.walk(pkgsinfo_path):
		# Managed Store apps belong to the Intune reconciliation pipeline. They are
		# not AutoPkg package metadata and must never enter promoter processing.
		dirs[:] = [
			directory for directory in dirs
			if os.path.abspath(os.path.join(root, directory)) != managed_path
		]
		result += [os.path.join(root, file) for file in files if file.endswith('.yaml') and not file.startswith(".")]
	return result

def prep_all_promotions(config, pkgsinfo_path, config_path):
	names = dict()
	versions = dict()
	custom_item_descriptions = dict()
	prepped_promotions = []
	promote_tos = dict()
	if config and "promotions" in config and type(config["promotions"]) == dict:
		promotions = config["promotions"]
		for file in get_pkgsinfo_paths(pkgsinfo_path):
			try:
				pkginfo = load_pkginfo(file)
				for promotion in config["promotions"]:
					promote_to, promote_from, days, custom_items = get_promotion_info(promotion, promotions, config, config_path)
					item_name, item_version, item_promotion, custom_promote_to = prep_item_for_promotion(pkginfo, promote_to, promote_from, days, custom_items, file)
					if item_name and check_selection(config, item_name) and check_created_by(config, pkginfo):
						if promotion not in names:
							names[promotion] = []
							versions[promotion] = []
							custom_item_descriptions[promotion] = {"names": [], "versions": [], "promote_tos": []}
							promote_tos[promotion] = promote_to
						if custom_promote_to:
							if "supported_architectures" in pkginfo:
								custom_item_descriptions[promotion]["names"].append(item_name + f" ({', '.join(pkginfo['supported_architectures'])})")
							else:
								custom_item_descriptions[promotion]["names"].append(item_name)
							custom_item_descriptions[promotion]["versions"].append(item_version)
							custom_item_descriptions[promotion]["promote_tos"].append(custom_promote_to)
						else:
							if "supported_architectures" in pkginfo:
								names[promotion].append(item_name + f" ({', '.join(pkginfo['supported_architectures'])})")
							else:
								names[promotion].append(item_name)
							versions[promotion].append(item_version)
						prepped_promotions.append(item_promotion)
						break
			except Exception as e:
				logging.error(f"Could not load file {file} in pkgsinfo directory.")
				logging.error(e, exc_info=True)
				sys.exit(1)
		return names, versions, custom_item_descriptions, prepped_promotions, promote_tos
	else:
		logging.error(f'No promotions are currently defined in {config_path}.')
		sys.exit(1)

def prep_single_promotion(promotion, config, pkgsinfo_path, config_path):
	if config and "promotions" in config and type(config["promotions"]) == dict:
		promotions = config["promotions"]
		if does_promotion_exist(promotion, promotions):
			promote_to, promote_from, days, custom_items = get_promotion_info(promotion, promotions, config, config_path)
			names, version, custom_item_descriptions, promotions = prep_pkgsinfo_single_promotion(promote_to, promote_from, days, custom_items, pkgsinfo_path, config)
			return names, version, custom_item_descriptions, promotions, promote_to
		else:
			logging.error(f'Promotion "{promotion}" not found! Use --list to see valid catalogs to promote. Promotions can be configured in {config_path}.')
			sys.exit(1)
	else:
		logging.error(f'No promotions are currently defined in {config_path}.')
		sys.exit(1)

def prep_pkgsinfo_single_promotion(promote_to, promote_from, days, custom_items, pkgsinfo_path, config):
	names = []
	versions = []
	promotions = []
	custom_item_descriptions = {"names": [], "versions": [], "promote_tos": []}
	for file in get_pkgsinfo_paths(pkgsinfo_path):
		try:
			pkginfo = load_pkginfo(file)
			item_name, item_version, item_promotion, custom_promote_to = prep_item_for_promotion(pkginfo, promote_to, promote_from, days, custom_items, file)
			if item_name and check_selection(config, item_name) and check_created_by(config, pkginfo):
				if custom_promote_to:
					if "supported_architectures" in pkginfo:
						custom_item_descriptions["names"].append(item_name + f" ({', '.join(pkginfo['supported_architectures'])})")
					else:
						custom_item_descriptions["names"].append(item_name)
					custom_item_descriptions["versions"].append(item_version)
					custom_item_descriptions["promote_tos"].append(custom_promote_to)
				else:
					if "supported_architectures" in pkginfo:
						names.append(item_name + f" ({', '.join(pkginfo['supported_architectures'])})")
					else:
						names.append(item_name)
					versions.append(item_version)
				promotions.append(item_promotion)
		except Exception as e:
			logging.error(f"Could not load file {file} in pkgsinfo directory.")
			logging.error(e, exc_info=True)
			sys.exit(1)
	return names, versions, custom_item_descriptions, promotions

def prep_item_for_promotion(item, promote_to, promote_from, days, custom_items, item_path):
	changed_promote_to = False
	try:
		item_name = item["name"]
		item_version = item["version"]
		item_catalogs = item["catalogs"]
	except Exception:
		logging.error(f"File {item_path} is missing expected keys.", exc_info=True)
		sys.exit(1)
	# check if custom item
	is_custom = item_name in custom_items and type(custom_items[item_name]) == dict
	# Restrict auto-promotion to autopkg-imported items. A custom_items entry is
	# an explicit opt-in, so it overrides the gate (e.g. the same-day browsers,
	# which may be stamped by the import pipeline rather than autopkg itself).
	if not is_custom and not is_autopkg_created(item):
		return None, None, None, None
	if is_custom:
		if "days_in_catalog" in custom_items[item_name]:
			days = custom_items[item_name]["days_in_catalog"]
		if "promote_to" in custom_items[item_name] and type(custom_items[item_name]["promote_to"]) == list and len(custom_items[item_name]["promote_to"]) > 0:
			promote_to = custom_items[item_name]["promote_to"]
			changed_promote_to = True
		if "promote_from" in custom_items[item_name] and type(custom_items[item_name]["promote_from"]) == list and len(custom_items[item_name]["promote_from"]) > 0:
			promote_from = custom_items[item_name]["promote_from"]
	# check if eligible for promotion based on current catalogs
	if set(item_catalogs) == set(promote_from):
		# check if eligible for promotion based on days
		today = datetime.datetime.utcnow()
		eval_time = EVAL_TIME if EVAL_TIME else today
		last_edited_date = today
		if "_metadata" in item:
			if "cimian-promoter_edit_date" in item["_metadata"]:
				last_edited_date = item["_metadata"]["cimian-promoter_edit_date"]
			elif "creation_date" in item["_metadata"]:
				last_edited_date = item["_metadata"]["creation_date"]
				logging.info(f"File {item_path} is missing a last edit date so the creation date {last_edited_date} will be used with the assumption that this item has been in the current catalog(s) since creation.")
			else:
				item["_metadata"]["cimian-promoter_edit_date"] = today
				logging.info(f"File {item_path} is missing a creation date so cimian-promoter will set the last edit date to today.")
				try_add_metadata(item_path, item)
		else:
			item["_metadata"] = {"cimian-promoter_edit_date": today}
			logging.info(f"File {item_path} is missing a creation date so cimian-promoter will set the last edit date to today.")
			try_add_metadata(item_path, item)
		if last_edited_date + datetime.timedelta(days=days) < eval_time:
			# up for promotion!
			item["catalogs"] = promote_to
			item["_metadata"]["cimian-promoter_edit_date"] = today
			if changed_promote_to:
				return item_name, item_version, (item_path, item), promote_to
			else:
				return item_name, item_version, (item_path, item), None
	return None, None, None, None

def promote_items(prepped_promotions):
	for item_path, item in prepped_promotions:
		try:
			logging.info(f"Promoting {item_path} to {item['catalogs']}")
			save_pkginfo(item_path, item)
		except Exception as e:
			logging.error(f"Could not write to file {item_path} in pkgsinfo directory.")
			logging.error(e, exc_info=True)
			sys.exit(1)

def try_add_metadata(item_path, item):
	try:
		logging.info(f"Adding missing metadata to file {item_path}")
		save_pkginfo(item_path, item)
	except Exception:
		logging.warning(f"File {item_path} is missing metadata and this file can not be written to.", exc_info=True)

def prep_set_edit_date(pkgsinfo_path, config, overwrite=False, promotion=None, promote_from_days=None, config_path=None):
	if promotion:
		if config and "promotions" in config and type(config["promotions"]) == dict:
			promotions = config["promotions"]
			if does_promotion_exist(promotion, promotions):
				_, promote_from, _, custom_items = get_promotion_info(promotion, promotions, config, config_path)
				return prep_pkgsinfo_edit_date(pkgsinfo_path, config, promote_from=promote_from, promote_from_days=promote_from_days, custom_items=custom_items)
			else:
				logging.error(f'Promotion "{promotion}" not found! Use --list to see valid catalogs to promote. Promotions can be configured in {config_path}.')
				sys.exit(1)
		else:
			logging.error(f'No promotions are currently defined in {config_path}.')
			sys.exit(1)
	else:
		return prep_pkgsinfo_edit_date(pkgsinfo_path, config, overwrite=overwrite)

def prep_pkgsinfo_edit_date(pkgsinfo_path, config, overwrite=False, promote_from=None, promote_from_days=None, custom_items=None):
	names = []
	changes = []
	for file in get_pkgsinfo_paths(pkgsinfo_path):
		try:
			pkginfo = load_pkginfo(file)
			item_name, item = prep_item_edit_date(pkginfo, file, overwrite, promote_from, promote_from_days, custom_items)
			if item_name and check_selection(config, item_name) and check_created_by(config, pkginfo):
				names.append(item_name)
				changes.append(item)
		except Exception as e:
			logging.error(f"Could not load file {file} in pkgsinfo directory.")
			logging.error(e, exc_info=True)
			sys.exit(1)
	return names, changes

def prep_item_edit_date(item, item_path, overwrite, promote_from, promote_from_days, custom_items):
	try:
		item_name = item["name"]
		if promote_from:
			item_catalogs = item["catalogs"]
	except Exception:
		logging.error(f"File {item_path} is missing expected keys.", exc_info=True)
		sys.exit(1)
	if promote_from and (item_name in custom_items and type(custom_items[item_name]) == dict):
		if "promote_from" in custom_items[item_name] and type(custom_items[item_name]["promote_from"]) == list and len(custom_items[item_name]["promote_from"]) > 0:
			promote_from = custom_items[item_name]["promote_from"]
	if "_metadata" not in item:
		item["_metadata"] = dict()
	if overwrite or ("cimian-promoter_edit_date" not in item["_metadata"]):
		today = datetime.datetime.utcnow()
		if promote_from:
			if set(item_catalogs) == set(promote_from):
				if "creation_date" not in item["_metadata"]:
					logging.info(f"File {item_path} is missing a creation date so cimian-promoter will set the last edit date to today.")
					item["_metadata"]["cimian-promoter_edit_date"] = today
					return item_name, (item_path, item)
				else:
					creation_date = item["_metadata"]["creation_date"]
					last_edited_date = creation_date + datetime.timedelta(days=promote_from_days)
					item["_metadata"]["cimian-promoter_edit_date"] = last_edited_date
					return item_name, (item_path, item)
		else:
			item["_metadata"]["cimian-promoter_edit_date"] = today
			return item_name, (item_path, item)
	return None, None

def check_created_by(config, pkginfo):
	# The promoter walks every pkginfo under the pkgsinfo path, not only the ones
	# AutoPkg produced, so a hand-imported item used to ride the whole
	# Development -> Testing -> Staging -> Production cycle unattended. When
	# selection.created_by is set, only pkgsinfo whose _metadata.created_by
	# matches one of those values are eligible for promotion.
	if not config or "selection" not in config or type(config["selection"]) != dict:
		return True
	allowed = config["selection"].get("created_by")
	if not allowed or type(allowed) != list:
		return True
	metadata = pkginfo.get("_metadata") if type(pkginfo) == dict else None
	created_by = metadata.get("created_by") if type(metadata) == dict else None
	return created_by in allowed

def check_selection(config, item_name):
	if config and "selection" in config and "type" in config["selection"]:
		if config["selection"]["type"] == "inclusion":
			if "items" not in config["selection"] or type(config["selection"]["items"]) != list:
				return False
			return item_name in config["selection"]["items"]
		elif config["selection"]["type"] == "exclusion":
			if "items" not in config["selection"] or type(config["selection"]["items"]) != list:
				return True
			return item_name not in config["selection"]["items"]
	return True

# ----------------------------------------
#              User input
# ----------------------------------------
def user_confirm(s):
	print(s)
	print('Do you want to proceed? [y/n] ', end='')
	while True:
		try:
			return _BOOLMAP[str(input()).lower()]
		except Exception:
			print("Please respond with 'y' or 'n'.\n")

# ----------------------------------------
# 				Main
# ----------------------------------------

def process_options():
	parser = optparse.OptionParser()
	parser.set_usage('Usage: %prog [options]')
	parser.add_option('--promotion', '-p', dest='promotion',
						help='Specifies the name of the promotion to run. If not set, all promotions in the configuration will be run. Use --list to see available promotions.')
	parser.add_option('--list', '-l', dest='list', action='store_true',
						help='Prints the list of possible promotions.')
	parser.add_option('--pkgsinfo', '-m', dest='pkgsinfo_path', default=PKGSINFO_PATH,
						help=f'Optional path to the pkgsinfo directory, defaults to {PKGSINFO_PATH}')
	parser.add_option('--yaml', '-y', dest='config_file',
						help='Optional path to the configuration yaml file. Defaults to promoter.yml if not set.')
	parser.add_option('--markdown', dest='markdown_path',
						help='Optional file name to print markdown summary of promotions.')
	parser.add_option('--auto', '-a', dest='auto', action='store_true',
						help='Run without interaction.')
	parser.add_option('--dry-run', dest='dry_run', action='store_true',
						help='Preview what would be promoted without making changes. Implies --auto.')
	parser.add_option('--as-of', dest='as_of_utc_hour', type='int',
						help='Evaluate eligibility as of this UTC hour today (e.g. 18 for 18:00 UTC). Used by preview runs to match actual promotion time.')
	parser.add_option('--reset-edit-date', dest='reset_edit', action='store_true',
						help='Reset the last edited day of all items to today.')
	parser.add_option('--set-unknown-edit-date', dest='set_edit', action='store_true',
						help='Set all missing last edited days to today.')
	parser.add_option('--days-before-current-catalog', dest='promote_from_days', type='int',
						help='Requires --promotion. For matching items, if last edit date is unknown, calculate it assuming n days to reach current catalog.')
	options, _ = parser.parse_args()
	# dry-run implies auto
	auto = options.auto or options.dry_run
	dry_run = options.dry_run
	as_of_utc_hour = options.as_of_utc_hour
	if options.config_file:
		return options.promotion, options.list, options.pkgsinfo_path, options.config_file, True, options.markdown_path, auto, options.reset_edit, options.set_edit, options.promote_from_days, dry_run, as_of_utc_hour
	return options.promotion, options.list, options.pkgsinfo_path, CONFIG_FILE, False, options.markdown_path, auto, options.reset_edit, options.set_edit, options.promote_from_days, dry_run, as_of_utc_hour

def setup_logging():
	logging.basicConfig(
		level=logging.DEBUG,
		format="%(asctime)s - %(levelname)s (%(module)s): %(message)s",
		datefmt='%d/%m/%Y %H:%M:%S',
		stream=sys.stdout)

def main():
	setup_logging()
	promotion, show_list, pkgsinfo_path, config_path, is_config_specified, md_path, auto, reset_edit, set_edit, promote_from_days, dry_run, as_of_utc_hour = process_options()
	config = get_config(config_path, is_config_specified)

	global EVAL_TIME
	if as_of_utc_hour is not None:
		now = datetime.datetime.utcnow()
		EVAL_TIME = now.replace(hour=as_of_utc_hour, minute=0, second=0, microsecond=0)
		logging.info(f"Evaluating eligibility as of {EVAL_TIME} UTC (--as-of {as_of_utc_hour})")

	if reset_edit or set_edit or promote_from_days:
		check_selection_specified_correctly(config, config_path)
		if reset_edit:
			logging.info('Reset the last edited day of all items to today.')
			names, prepped_changes = prep_set_edit_date(pkgsinfo_path, config, overwrite=True)
		elif set_edit:
			logging.info('Setting all missing last edited days to today.')
			names, prepped_changes = prep_set_edit_date(pkgsinfo_path, config)
		elif promote_from_days:
			if not promotion:
				logging.error("--days-before-current-catalog requires --promotion.")
				sys.exit(1)
			else:
				logging.info(f'Setting missing last edited days for "{promotion}", assuming {promote_from_days} days to reach current catalog(s).')
				names, prepped_changes = prep_set_edit_date(pkgsinfo_path, config, promotion=promotion, promote_from_days=promote_from_days, config_path=config_path)
		if names:
			s = f'The metadata of the following items will be updated: {and_str(names)}'
			if auto or user_confirm(s):
				for prepped_change in prepped_changes:
					item_path, item = prepped_change
					try_add_metadata(item_path, item)
			else:
				logging.info('Ok, aborted..')
		else:
			logging.info("No metadata need to be updated.")

	elif show_list:
		print_promotions(config, config_path)

	elif promotion:
		check_selection_specified_correctly(config, config_path)
		names, versions, custom_item_descriptions, prepped_promotions, promote_to = prep_single_promotion(promotion, config, pkgsinfo_path, config_path)
		if names:
			s = describe_promotion(promotion, promote_to, names, versions, custom_item_descriptions)
			if auto or user_confirm(s):
				if dry_run:
					logging.info('Dry run -- skipping file writes.')
				else:
					promote_items(prepped_promotions)
				if md_path:
					md = md_description(promotion, promote_to, names, versions, custom_item_descriptions)
					write_md_file(md_path, md)
			else:
				logging.info('Ok, aborted..')
		else:
			logging.info("No items need to be promoted.")

	else:
		check_selection_specified_correctly(config, config_path)
		names_dict, versions_dict, custom_item_descriptions_dict, prepped_promotions, promote_tos = prep_all_promotions(config, pkgsinfo_path, config_path)
		if len(names_dict) > 0:
			s = ""
			for promotion in config["promotions"]:
				if promotion in names_dict:
					s += describe_promotion(promotion, promote_tos[promotion], names_dict[promotion], versions_dict[promotion], custom_item_descriptions_dict[promotion])
			if auto or user_confirm(s):
				if dry_run:
					logging.info('Dry run -- skipping file writes.')
				else:
					promote_items(prepped_promotions)
				if md_path:
					md = ""
					for promotion in config["promotions"]:
						if promotion in names_dict:
							md += md_description(promotion, promote_tos[promotion], names_dict[promotion], versions_dict[promotion], custom_item_descriptions_dict[promotion])
					write_md_file(md_path, md)
			else:
				logging.info('Ok, aborted..')
		else:
			logging.info("No items need to be promoted.")

if __name__ == '__main__':
	main()
