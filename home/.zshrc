# ~/.zshrc — interactive shell config

# --- History ---------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS

# --- Shell behaviour -------------------------------------------------------
setopt AUTO_CD INTERACTIVE_COMMENTS NO_BEEP
bindkey -e                              # emacs-style line editing
export EDITOR=nvim VISUAL=nvim
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"   # ~/go/bin: tools from `go install`
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"   # Rust: cargo-installed tools, rustup toolchain
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools   # Android SDK (brew android-commandlinetools), for Gradle builds
export PATH="$ANDROID_HOME/platform-tools:$PATH"   # adb and fastboot from that SDK

# --- Colours (Tokyo Night) -------------------------------------------------
export LS_COLORS="$(vivid generate tokyonight-night)"   # file-type colours for eza & completion
export EZA_COLORS="ur=38;2;115;122;162:uw=38;2;115;122;162:ux=38;2;115;122;162:ue=38;2;115;122;162:gr=38;2;115;122;162:gw=38;2;115;122;162:gx=38;2;115;122;162:tr=38;2;115;122;162:tw=38;2;115;122;162:tx=38;2;115;122;162:da=38;2;86;95;137:uu=38;2;86;95;137:un=38;2;86;95;137:gu=38;2;86;95;137:gn=38;2;86;95;137:xx=38;2;86;95;137:hd=38;2;86;95;137:sn=38;2;115;122;162:sb=38;2;86;95;137"   # quiet greys for permissions, owner, size, dates
export BAT_THEME=ansi                                   # follow the terminal palette
export MANPAGER="sh -c 'col -bx | bat -l man -p'"       # syntax-coloured man pages
export MANROFFOPT=-c

# --- Completion ------------------------------------------------------------
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no                           # fzf-tab draws the menu
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*:git-checkout:*' sort false

# Up/Down search history by what's already typed
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search

# --- Tools -----------------------------------------------------------------
eval "$(mise activate zsh)"             # node, python, ... versions
eval "$(zoxide init zsh)"               # z <dir>, zi
source <(fzf --zsh)                     # Ctrl-R history, Ctrl-T files, Alt-C cd

export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS="
  --height=50% --layout=reverse --border=none --info=inline-right --no-separator
  --prompt='> ' --pointer='▎' --marker='+'
  --color=fg:#c0caf5,bg:-1,hl:#7aa2f7
  --color=fg+:#c0caf5,bg+:#292e42,hl+:#7dcfff,gutter:-1
  --color=info:#565f89,prompt:#7aa2f7,pointer:#bb9af7
  --color=marker:#9ece6a,spinner:#bb9af7,header:#565f89,border:#3b4261"
export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range :200 {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always --icons=always {}'"

# Tab completion as a fuzzy menu, with previews for directories and files
source /opt/homebrew/opt/fzf-tab/share/fzf-tab/fzf-tab.zsh
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' fzf-flags --height=50%
zstyle ':fzf-tab:complete:(cd|z|ls|ll|la|lt):*' fzf-preview 'eza -1 --color=always --icons=always $realpath'
zstyle ':fzf-tab:complete:(cat|bat|nvim|vim):*' fzf-preview \
  '[[ -d $realpath ]] && eza -1 --color=always --icons=always $realpath || bat --color=always --style=numbers --line-range :200 $realpath'

# --- Aliases ---------------------------------------------------------------
alias ls='eza --group-directories-first --icons=auto'
alias ll='eza -l --no-user --git --time-style=relative --group-directories-first --icons=auto'
alias la='eza -lah --git --time-style=relative --group-directories-first --icons=auto'
alias lt='eza --tree --level=2 --group-directories-first --icons=auto'
alias cat='bat --paging=never'
alias vim='nvim'
alias g='git'
alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'
alias ..='cd ..'
alias ...='cd ../..'
alias reload='exec zsh'

# --- Prompt & plugins (keep last) ------------------------------------------
eval "$(starship init zsh)"

source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#565f89'

source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSH_HIGHLIGHT_STYLES[command]='fg=#7aa2f7'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#7aa2f7'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#7aa2f7'
ZSH_HIGHLIGHT_STYLES[function]='fg=#7aa2f7'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=#7aa2f7,italic'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#f7768e'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=#bb9af7'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=#ff9e64'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=#ff9e64'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#9ece6a'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#9ece6a'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=#7dcfff'
ZSH_HIGHLIGHT_STYLES[path]='fg=#c0caf5,underline'
ZSH_HIGHLIGHT_STYLES[comment]='fg=#565f89'

# claude-pulse: begin (do not edit)
# Terminal id, TTY-hash-derived for per-tab uniqueness.
export CLAUDE_PULSE_TERMINAL_ID="$(tty 2>/dev/null | shasum 2>/dev/null | cut -c1-16)"
[ -z "$CLAUDE_PULSE_TERMINAL_ID" ] && export CLAUDE_PULSE_TERMINAL_ID="${CLAUDE_PULSE_TERMINAL_ID_FALLBACK:-$(uuidgen 2>/dev/null || echo "cp-$$-$RANDOM")}"
# Ghostty surface id — only pay the AppleScript cost inside Ghostty,
# and only once per shell (first new tab). Keeps iTerm2, Terminal.app,
# WezTerm etc. from triggering macOS Automation-permission prompts.
case "$TERM_PROGRAM" in
  ghostty)
    if [ -z "$CLAUDE_PULSE_GHOSTTY_ID" ]; then
      export CLAUDE_PULSE_GHOSTTY_ID="$(osascript -e 'tell application "Ghostty" to return id of focused terminal of selected tab of front window' 2>/dev/null)"
    fi
    ;;
esac
# claude-pulse: end
