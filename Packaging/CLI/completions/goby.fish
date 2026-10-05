complete -c goby -f
complete -c goby -n 'not __fish_seen_subcommand_from status projects add use run watch result diff log approve deny pause resume cancel follow-up commit push ask diagnostics doctor login logout import-agents uninstall automations automation host' -a 'status projects add use run watch result diff log approve deny pause resume cancel follow-up commit push ask diagnostics doctor login logout import-agents uninstall automations automation host'
complete -c goby -n '__fish_seen_subcommand_from host' -a 'run status stop'
complete -c goby -n '__fish_seen_subcommand_from login logout' -a 'codex claude copilot'
complete -c goby -l json -d 'Versioned JSON output'
complete -c goby -l verbose -d 'Activity details'
complete -c goby -l yes -d 'Approve the displayed scope'
complete -c goby -l provider -r -a 'codex claude copilot'
complete -c goby -l store -r -a '(__fish_complete_directories)'
complete -c goby -l help
complete -c goby -l version
