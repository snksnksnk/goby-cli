_goby_complete() {
  local commands='status projects add use run watch result diff log approve deny pause resume cancel follow-up commit push ask diagnostics doctor login logout import-agents uninstall automations automation host'
  if [[ $COMP_CWORD == 1 ]]; then
    COMPREPLY=( $(compgen -W "$commands --json --verbose --yes --provider --store --help --version" -- "${COMP_WORDS[COMP_CWORD]}") )
  elif [[ ${COMP_WORDS[COMP_CWORD-1]} == --provider || ${COMP_WORDS[1]} == login || ${COMP_WORDS[1]} == logout ]]; then
    COMPREPLY=( $(compgen -W 'codex claude copilot' -- "${COMP_WORDS[COMP_CWORD]}") )
  elif [[ ${COMP_WORDS[1]} == host ]]; then
    COMPREPLY=( $(compgen -W 'run status stop --stay-alive' -- "${COMP_WORDS[COMP_CWORD]}") )
  fi
}
complete -F _goby_complete goby
