" vimrc — shared by terminal Vim and gVim. GUI-only settings live in ~/.gvimrc.
" Target: Vim 8.2+.

set encoding=utf-8
set nocompatible
set fileencoding=utf-8

" --- Line endings ---
" Both formats must stay in the detection list: with unix alone, a CRLF file
" is read as unix and every CR becomes a literal ^M in the buffer.
set fileformats=unix,dos
set fileformat=unix

" CRLF -> LF on demand. filewritable() returns 1 for a writable file, 0 for
" read-only, and 2 when the argument is a writable directory.
function! s:FixEOL() abort
  let l:f = expand('%:p')
  if empty(l:f) || &readonly || !&modifiable
        \ || (filewritable(l:f) != 1 && filewritable(fnamemodify(l:f, ':h')) != 2)
    echomsg 'FixEOL: cannot write here'
    return
  endif
  silent! %s/\r$//e
  setlocal ff=unix
  write!
endfunction
command! FixEOL call <SID>FixEOL()

" 1 on a machine that reads/writes CJK text; forks the listchars pair below.
let g:vim_cjk = get(g:, 'vim_cjk', 0)

" --- Explore / find ---
let g:netrw_liststyle = 3
let g:netrw_keepdir  = 0

let mapleader = '\'

" Leader keys in use
"   e find file      t tagbar        g gundo      li LspInstallServer
"   rg grep          rw grep word    dc diffconflicts
"   ss workspace symbol   ds document symbols   rn rename   ca code action
"   | table mode (|m |t |dd |dc)

" GFiles inside a repo (cwd is already at the root via vim-rooter), Files otherwise.
function! s:FindFiles() abort
  if exists(':GFiles') != 2
    echomsg 'fzf.vim not loaded — run :PlugInstall'
    return
  endif
  if !empty(globpath(getcwd(), '.git'))
    GFiles
  else
    Files
  endif
endfunction
command! FindFiles call <SID>FindFiles()
nnoremap <Leader>e :FindFiles<CR>

" Auto-install vim-plug if missing.
let s:plug_file = expand('~/.vim/autoload/plug.vim')
if !filereadable(s:plug_file)
  silent execute '!curl -fLo ' . shellescape(s:plug_file)
    \ . ' --create-dirs'
    \ . ' https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  augroup plug_bootstrap
    autocmd!
    autocmd VimEnter * ++once silent! PlugInstall --sync | redraw! | source $MYVIMRC
  augroup END
endif

" --- Plugins ---
call plug#begin('~/.vim/plugged')

Plug 'junegunn/fzf'
Plug 'junegunn/fzf.vim'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'tpope/vim-vinegar'
Plug 'tpope/vim-surround'
Plug 'jiangmiao/auto-pairs'
Plug 'kshenoy/vim-signature'
Plug 'godlygeek/tabular'                " must precede vim-markdown
Plug 'preservim/vim-markdown'
Plug 'noahfrederick/vim-hemisu'         " CC BY-NC 3.0: referenced, not vendored

Plug 'prabirshrestha/vim-lsp'
Plug 'prabirshrestha/vim-lsp-settings'
Plug 'preservim/tagbar'
Plug 'ludovicchabant/vim-gutentags'
Plug 'airblade/vim-rooter'
Plug 'tpope/vim-fugitive'
Plug 'whiteinge/diffconflicts'
Plug 'tpope/vim-commentary'
Plug 'dhruvasagar/vim-table-mode'
Plug 'lervag/vimtex', { 'for': 'tex' }
if has('python3')
  Plug 'sjl/gundo.vim'
endif

" ALE is a linter runner, not a language server; nothing here depends on it.
" Plug 'dense-analysis/ale'

call plug#end()

" --- Core ---
" Must precede filetype detection, or a .tex without \documentclass is plaintex.
let g:tex_flavor = 'latex'

filetype plugin indent on
syntax on

set number
set relativenumber
set numberwidth=5

set tabstop=4
set shiftwidth=4
set softtabstop=4
set expandtab
set shiftround                      " >> rounds to a multiple of shiftwidth
set smartindent
set autoindent

set backspace=indent,eol,start
set wrap
set linebreak
set showbreak=>\
set scrolloff=5
set hidden
set history=1000

" --- Whitespace + CJK ---
" With ambiwidth=double every pretty listchars glyph is East-Asian Ambiguous
" width, so the two settings are a fork, not a pair.
set list

if g:vim_cjk
  set ambiwidth=double
  set formatoptions+=mM             " break at multibyte; no space on join
  set listchars=tab:>-,trail:-,extends:>,precedes:<,nbsp:+
else
  set listchars=tab:»·,trail:·,extends:»,precedes:«,nbsp:␣
endif

" --- Folds ---
" ff/fd/fa shadow f{char}: pressing f then f waits 'timeoutlen'.
set foldmethod=manual

nnoremap ff za
vnoremap ff za
nnoremap fd zd
vnoremap fd zd
nnoremap fa zF
vnoremap fa zF

" Must be global: 'foldtext' is evaluated later, where <SID> is not expanded.
function! NeatFoldText() abort
  let l:line  = ' ' . substitute(getline(v:foldstart), '^\s*"\?\s*\|\s*"\?\s*{{' . '{\d*\s*', '', 'g') . ' '
  let l:count = v:foldend - v:foldstart + 1
  let l:ctext = '| ' . printf('%10s', l:count . ' lines') . ' |'
  let l:fill  = matchstr(&fillchars, 'fold:\zs.')
  if empty(l:fill)
    let l:fill = '-'
  endif
  let l:start = strpart('+' . repeat(l:fill, v:foldlevel * 2) . l:line, 0, (winwidth(0) * 2) / 3)
  let l:end   = l:ctext . repeat(l:fill, 8)
  let l:len   = strlen(substitute(l:start . l:end, '.', 'x', 'g')) + &foldcolumn
  return l:start . repeat(l:fill, winwidth(0) - l:len) . l:end
endfunction

set foldtext=NeatFoldText()

" --- Spell ---
" sb shadows "substitute back to word start".
set spell
set spelllang=en_us
set spellsuggest=7
set complete+=kspell                " spell suggestions in insert completion

nnoremap <silent> sf ]s
nnoremap <silent> sb [s
nnoremap <silent> s= z=

" Refuse to touch the spellfile from the keyboard.
nnoremap zg  <Nop>
nnoremap zG  <Nop>
nnoremap zw  <Nop>
nnoremap zW  <Nop>
nnoremap zuw <Nop>
nnoremap zug <Nop>
nnoremap zuW <Nop>
nnoremap zuG <Nop>

" --- Clipboard ---
" Empty in the terminal: unnamedplus makes every delete write to the Windows
" clipboard, spawning clip.exe and clobbering what you copied outside Vim.
" gVim sets unnamedplus in .gvimrc.
set clipboard=

if has('wsl') || system('uname -r') =~? 'microsoft'
  let g:clipboard = {
    \ 'name': 'wsl-windows',
    \ 'copy': { '+': 'clip.exe', '*': 'clip.exe' },
    \ 'paste': {
    \   '+': 'powershell.exe -NoProfile -Command [Console]::Out.Write($(Get-Clipboard -Raw).ToString().replace("`r",""))',
    \   '*': 'powershell.exe -NoProfile -Command [Console]::Out.Write($(Get-Clipboard -Raw).ToString().replace("`r",""))',
    \ },
    \ 'cache_enabled': 0,
    \ }
endif

xnoremap <Leader>y "+y
nnoremap <Leader>y "+y
nnoremap <Leader>Y :%y+<CR>
nnoremap <Leader>p "+p
nnoremap <Leader>P "+P
inoremap <Leader>p <C-r>+

" --- Search ---
set incsearch
set hlsearch
set ignorecase
set smartcase

nnoremap <silent> <Esc><Esc> :nohlsearch<CR>

" --- UI ---
set laststatus=2
set showcmd
set showmatch
set wildmenu
set wildmode=list:longest
set cursorline
set signcolumn=yes                  " vim-signature marks
silent! set shortmess+=c
set updatetime=300

" --- Window layout ---
" signcolumn, number and colorcolumn are window-local: a FileType autocmd
" leaves them set for every buffer opened later in that window.
function! s:WindowLook() abort
  if &columns < 100
    silent! setlocal signcolumn=auto
    setlocal nonumber
  else
    silent! setlocal signcolumn=yes
    setlocal number
  endif

  " colorcolumn=+1 with textwidth 0 resolves to column 1, so leave it empty.
  if &filetype =~# '^\(java\|xml\|json\)$'
    setlocal colorcolumn=120
  elseif &textwidth > 0
    silent! setlocal colorcolumn=+1
  else
    setlocal colorcolumn=
  endif
endfunction

augroup window_look
  autocmd!
  autocmd VimEnter,VimResized,BufWinEnter,FileType * call s:WindowLook()
augroup END

" --- View persistence ---
set viewoptions-=options
call mkdir(expand('~/.vim/view'), 'p')

augroup view_persist
  autocmd!
  autocmd BufWinLeave ?* silent! mkview
  autocmd BufWinEnter ?* silent! loadview
augroup END

" --- Splits ---
set splitright
set splitbelow

" <C-w>h/j/k/l navigates. Resize needs modified arrows in terminfo; check with
" <C-v><C-Right> in insert mode.
nnoremap <C-right> 5<C-W>>
nnoremap <C-left>  5<C-W><
nnoremap <C-up>    5<C-W>+
nnoremap <C-down>  5<C-W>-

" --- Terminal ---
set ttimeout
set ttimeoutlen=100
set timeoutlen=500

set noerrorbells
set visualbell
set t_vb=

" --- Colour ---
" t_Co comes from terminfo, never set here. Hemisu is CC BY-NC 3.0, so it is
" a plugin, not vendored into this GPL-3.0 repo.
if !has('gui_running')
  if $COLORTERM ==# 'truecolor' && $TERM !~# '^screen'
    set termguicolors
  elseif has('termguicolors')
    set notermguicolors
  endif
endif

set background=dark

silent! colorscheme hemisu
if get(g:, 'colors_name', '') !=# 'hemisu'
  silent! colorscheme desert         " built-in since forever
endif

" --- vim-airline ---
let g:airline_theme = 'solarized_flood'
let g:airline_powerline_fonts = 0
let g:airline#extensions#whitespace#enabled = 0

if empty(globpath(&rtp, 'autoload/airline/themes/' . g:airline_theme . '.vim'))
  echomsg 'airline: no theme file for "' . g:airline_theme . '" — falling back to dark'
endif

" --- LSP statusline marker ---
" Do not gate on exists('*lsp#get_allowed_servers'): autoload functions are
" undefined until called, and this autocmd runs before vim-lsp's own.
function! s:LspCheck() abort
  if &buftype !=# '' || &filetype ==# ''
    return
  endif
  let l:servers = []
  try
    let l:servers = lsp#get_allowed_servers()
  catch /E117/
    return
  endtry
  if empty(l:servers)
    let b:lsp_missing = ' no-lsp:' . &filetype
  else
    unlet! b:lsp_missing
  endif
endfunction

augroup lsp_check
  autocmd!
  autocmd FileType * call s:LspCheck()
  autocmd User lsp_buffer_enabled unlet! b:lsp_missing
augroup END

let g:airline_section_error = '%{get(b:, "lsp_missing", "")}'

" --- Key maps ---
inoremap jj <Esc>
nnoremap vv ^vg_
cnoreabbrev Q q                     " Q enters Ex mode otherwise

" --- vim-markdown ---
let g:vim_markdown_folding_disabled  = 1
let g:vim_markdown_conceal           = 0
let g:vim_markdown_frontmatter       = 1
let g:vim_markdown_strikethrough     = 1
let g:vim_markdown_fenced_languages  = ['java', 'sh', 'json', 'yaml', 'sql']

" --- File-type overrides ---
augroup custom_filetypes
  autocmd!
  autocmd FileType markdown setlocal spell spelllang=en_us
  autocmd FileType markdown setlocal textwidth=80
  autocmd FileType yaml,json setlocal tabstop=2 shiftwidth=2 softtabstop=2
  autocmd FileType xml  setlocal foldmethod=indent foldlevelstart=4 foldminlines=0
  autocmd FileType json setlocal foldmethod=syntax foldminlines=0
augroup END

" --- netrw: f = Files, F = GFiles ---
augroup netrw_fzf
  autocmd!
  autocmd FileType netrw nnoremap <buffer> f :Files<CR>
  autocmd FileType netrw nnoremap <buffer> F :GFiles<CR>
augroup END

" --- Project root + tags ---
let g:project_markers = ['.git', 'pom.xml', 'build.gradle', 'package.json',
      \ 'Cargo.toml', 'go.mod', 'pyproject.toml', 'Makefile']

let g:rooter_patterns     = g:project_markers
let g:rooter_silent_chdir = 1

let g:gutentags_project_root = g:project_markers
let g:gutentags_cache_dir    = expand('~/.cache/tags')
let g:gutentags_ctags_exclude = [
      \ '*.min.js', '*.min.css', '*.lock',
      \ 'node_modules', 'target', 'build', 'dist', 'vendor', '.git',
      \ ]
let g:gutentags_ctags_extra_args = ['--fields=+niazS', '--extras=+q']

if !executable('ctags')
  let g:gutentags_enabled = 0
  echomsg 'vimrc: ctags not found — tags and tagbar disabled'
endif

set tags=./tags;,tags

" --- ripgrep ---
if executable('rg')
  let $FZF_DEFAULT_COMMAND = 'rg --files'
  set grepprg=rg\ --vimgrep\ --smart-case
  set grepformat=%f:%l:%c:%m
else
  echomsg 'vimrc: rg not found — :Rg, :Files and :grep are degraded'
endif
autocmd QuickFixCmdPost grep cwindow
nnoremap <Leader>rg :grep<Space>
nnoremap <Leader>rw :grep <C-r><C-w><CR>

" --- Tagbar ---
let g:tagbar_width     = 30
let g:tagbar_autofocus = 1
let g:tagbar_sort      = 0
nnoremap <silent> <Leader>t :TagbarToggle<CR>

" --- diffconflicts ---
nnoremap <silent> <Leader>dc :DiffConflicts<CR>

" --- Gundo ---
" has() is compile-time; exists(':GundoToggle') is false here.
let g:gundo_prefer_python3 = 1
if has('python3')
  nnoremap <silent> <Leader>g :GundoToggle<CR>
endif

" --- vim-table-mode ---
" Bare <Leader>| is also a complete mapping, so it waits 'timeoutlen'.
let g:table_mode_map_prefix      = '<Leader>\|'
let g:table_mode_corner          = '|'
let g:table_mode_corner_corner   = '|'
let g:table_mode_header_fillchar = '-'

nnoremap <silent> <Leader>\| :TableModeToggle<CR>

" --- vim-lsp ---
let g:lsp_diagnostics_enabled =
      \ empty(globpath(&rtp, 'autoload/ale.vim')) ? 1 : 0
let g:lsp_document_highlight_enabled = 0
let g:lsp_signs_enabled              = 0
let g:lsp_inlay_hints_enabled        = 0
let g:lsp_log_file                   = ''

nnoremap <silent> <Leader>li :LspInstallServer<CR>

" Buffer-local, so these cost nothing outside an attached buffer:
"   gd definition   gr references   K hover   gy type   gi implementation
"   ss workspace symbol   ds document symbols   rn rename   ca code action
function! s:on_lsp_buffer() abort
  setlocal omnifunc=lsp#complete
  nmap <buffer> gd <Plug>(lsp-definition)
  nmap <buffer> gy <Plug>(lsp-type-definition)
  nmap <buffer> gi <Plug>(lsp-implementation)
  nmap <buffer> gr <Plug>(lsp-references)
  nmap <buffer> K <Plug>(lsp-hover)
  nmap <buffer> <Leader>ss <Plug>(lsp-workspace-symbol-search)
  nmap <buffer> <Leader>ds <Plug>(lsp-document-symbol-search)
  nmap <buffer> <Leader>rn <Plug>(lsp-rename)
  nmap <buffer> <Leader>ca <Plug>(lsp-code-action)
endfunction

augroup lsp_attach
  autocmd!
  autocmd User lsp_buffer_enabled call s:on_lsp_buffer()
augroup END

" --- Completion ---
" Accept a popup with Enter. Nothing opens a popup automatically; this only
" matters after <C-x><C-o>.
inoremap <expr> <CR> pumvisible() ? "\<C-y>" : "\<CR>"
