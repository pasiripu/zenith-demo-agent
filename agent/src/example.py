import time


def build_scan_config(repo_name, options={}):
    """Build a scan configuration dict for a repository scan job."""
    options["repo"] = repo_name
    options["timestamp"] = time.time()
    options["enabled"] = True
    return options


def schedule_scans(repos):
    return [build_scan_config(r) for r in repos]
 
