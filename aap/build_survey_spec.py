#!/usr/bin/env python3
"""Build aap/survey_spec.json, the AAP job template survey, from deployments.txt.

AAP's multiple-select questions only offer the options listed in the survey, so
every deployment name has to appear there as well as in deployments.txt (which
is what "all" expands to). Generating the survey from the file keeps the two in
step: after editing deployments.txt, run this and upload the result.

    python3 aap/build_survey_spec.py            # rewrite aap/survey_spec.json
    python3 aap/build_survey_spec.py --check    # exit 1 if survey_spec.json is out of date
    python3 aap/build_survey_spec.py --choices  # print the Deployments options, one per line

deployments.txt is read with the same rules as the script and the playbook:
anything after '#' is a comment, names are separated by spaces, commas or new
lines, a line reading "all" is ignored, and duplicates are listed once.

Standard library only.
"""

import argparse
import json
import os
import sys

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DEPLOYMENTS = os.path.join(REPO_DIR, "deployments.txt")
DEFAULT_OUTPUT = os.path.join(REPO_DIR, "aap", "survey_spec.json")
ALL = "all"


def read_deployments(path):
    """Deployment names from a deployments file, in order, without duplicates."""
    names, seen = [], set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            for word in line.split("#", 1)[0].replace(",", " ").split():
                if word.lower() == ALL or word in seen:
                    continue
                seen.add(word)
                names.append(word)
    return names


def build_spec(deployments):
    def question(name, description, variable, kind, required, default="",
                 choices="", minimum=None, maximum=None):
        return {
            "question_name": name,
            "question_description": description,
            "required": required,
            "type": kind,
            "variable": variable,
            "min": minimum,
            "max": maximum,
            "default": default,
            "choices": choices,
            "new_question": True,
        }

    return {
        "name": "Reset Kibana state:storeInSessionStorage",
        "description": "Choose deployments and whether to preview (dry-run) or apply (execute).",
        "spec": [
            question(
                "Deployments",
                "Tick 'all' for every deployment in deployments.txt, or tick "
                "individual deployments. Deployments ticked alongside 'all' are "
                "already included.",
                "deployments", "multiselect", True,
                choices=[ALL] + deployments),
            question(
                "Exclude deployments",
                "Optional. Deployments to leave out, e.g. when 'all' is ticked.",
                "exclude_deployments", "multiselect", False,
                choices=list(deployments)),
            question(
                "Run mode",
                "dry-run reports what would change and changes nothing. "
                "execute changes the setting.",
                "run_mode", "multiplechoice", True,
                default="dry-run", choices=["dry-run", "execute"]),
            question(
                "Value to write",
                "set-false writes an explicit false (visible in Advanced "
                "Settings). reset-to-default removes the override, like the UI's "
                "Reset to default. Both leave the setting false.",
                "value_mode", "multiplechoice", True,
                default="set-false", choices=["set-false", "reset-to-default"]),
            question(
                "Spaces",
                "Optional. Only these Kibana space IDs, separated by commas "
                "(e.g. default,admin or default, admin). Leave blank for every "
                "space.",
                "spaces", "text", False, minimum=0, maximum=2048),
            question(
                "Skip spaces",
                "Optional. Kibana space IDs to leave alone, separated by commas "
                "(e.g. default,admin,infra or default, admin, infra). Leave blank "
                "to skip none.",
                "exclude_spaces", "text", False, minimum=0, maximum=2048),
            question(
                "Parallel jobs",
                "How many copies of the script run on the appserver at once. "
                "Deployments are split evenly between them.",
                "parallel_jobs", "integer", True,
                default=10, minimum=1, maximum=50),
            question(
                "Verify Kibana TLS",
                "Keep true. false skips certificate checks for Kibana (last "
                "resort).",
                "verify_ssl", "multiplechoice", True,
                default="true", choices=["true", "false"]),
            question(
                "Verbose logging",
                "true logs every Kibana API request (URLs only, never "
                "credentials).",
                "verbose", "multiplechoice", True,
                default="false", choices=["false", "true"]),
        ],
    }


def render(spec):
    return json.dumps(spec, indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--deployments-file", default=DEFAULT_DEPLOYMENTS,
                        help="deployments file to read (default: %(default)s)")
    parser.add_argument("--output", default=DEFAULT_OUTPUT,
                        help="survey spec to write or check (default: %(default)s)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="exit 1 if the survey spec does not match deployments.txt")
    mode.add_argument("--choices", action="store_true",
                      help="print the Deployments question's options, one per line")
    args = parser.parse_args()

    deployments = read_deployments(args.deployments_file)
    if not deployments:
        sys.exit("error: %s lists no deployments" % args.deployments_file)

    if args.choices:
        print("\n".join([ALL] + deployments))
        return

    text = render(build_spec(deployments))
    if args.check:
        try:
            with open(args.output, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != text:
            sys.exit("%s is out of date with %s - run: python3 aap/build_survey_spec.py"
                     % (args.output, args.deployments_file))
        print("%s matches %s (%d deployments)" % (args.output, args.deployments_file, len(deployments)))
        return

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s: %d deployments as choices" % (args.output, len(deployments)))


if __name__ == "__main__":
    main()
