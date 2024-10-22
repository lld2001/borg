;;; borg.el --- Assimilate Emacs packages as Git submodules  -*- lexical-binding:t -*-

;; Copyright (C) 2016-2022 Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Homepage: https://github.com/emacscollective/borg
;; Keywords: tools

;; Package-Version: 3.3.1-git
;; Package-Requires: (
;;     (emacs "26")
;;     (epkg "3.3.3")
;;     (magit "3.3.0"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;; This file contains code taken from GNU Emacs, which is
;; Copyright (C) 1976-2022 Free Software Foundation, Inc.

;;; Commentary:

;; The Borg assimilate Emacs packages as Git submodules.  Borg is
;; an alternative, bare-bones package manager for Emacs packages.

;; Please consult the manual for more information:
;; https://www.emacsmirror.net/manual/borg.

;; Borg can be used by itself or alongside `package.el'.  In the
;; latter case Borg itself should be installed from Melpa, which
;; is still experimental and not yet covered in the manual.  See
;; https://github.com/emacscollective/borg/issues/46 for now.

;;; Code:

(require 'autoload)
(require 'bytecomp)
(require 'cl-lib)
(require 'info)
(require 'pcase)
(require 'subr-x)

(declare-function eieio-oref "eieio-core" (obj slot))
(declare-function epkg "epkg" (name))
(declare-function epkgs "epkg" (&optional select predicates))
;; check-declare doesn't know about defclass.
;; (declare-function epkg-git-package-p "epkg" (obj))
;; (declare-function epkg-github-package-p "epkg" (obj))
;; (declare-function epkg-gitlab-package-p "epkg" (obj))
;; (declare-function epkg-orphaned-package-p "epkg" (obj))
(declare-function epkg-read-package "epkg" (prompt &optional default predicate))
(declare-function format-spec "format-spec"
                  (format specification &optional ignore-missing split))
(declare-function magit-get "magit-git" (&rest keys))
(declare-function magit-get-some-remote "magit-git" (&optional branch))
(declare-function org-texinfo-export-to-texinfo "ox-texinfo"
                  (&optional async subtreep visible-only body-only ext-plist))

(when (< emacs-major-version 26)
  (defun register-definition-prefixes (_file _prefixes)))

(defvar git-commit-mode-map)
(defvar compilation-mode-font-lock-keywords)

(eval-when-compile
  (require (quote eieio))
  (cl-pushnew 'url eieio--known-slot-names)
  (cl-pushnew 'mirror-url eieio--known-slot-names))

(define-obsolete-variable-alias 'borg-drone-directory
  'borg-drones-directory "Borg 3.2.0")
(define-obsolete-variable-alias 'borg-byte-compile-recursively
  'borg-compile-recursively "Borg 3.3.0")
(define-obsolete-function-alias 'borg-byte-compile
  #'borg-compile "Borg 3.3.0")

;;; Variables

(defvar borg-drones-directory
  (let* ((libdir (file-name-directory (directory-file-name
                                       (file-name-directory
                                        (file-truename
                                         (or load-file-name
                                             buffer-file-name))))))
         (topdir (file-name-directory (directory-file-name libdir))))
    (or (ignore-errors
          (let ((default-directory topdir))
            (expand-file-name
             (car (process-lines "git" "config" "borg.drones-directory")))))
        (if (ignore-errors
              (file-equal-p libdir (bound-and-true-p package-user-dir)))
            (expand-file-name (file-name-as-directory "borg") topdir)
          libdir)))
  "Directory beneath which drone submodules are placed.
If you need to change this, then do so before loading `borg'.")

(defconst borg-user-emacs-directory
  (file-name-directory (directory-file-name borg-drones-directory))
  "Directory beneath which additional per-user Emacs-specific files are placed.

The value of this variable is usually the same as that of
`user-emacs-directory', except when Emacs is started with
`emacs -q -l /path/to/init.el'.")

(defvar borg-top-level-directory
  borg-user-emacs-directory
  "The top-level of repository containing `borg-user-emacs-directory'.")

(defvar borg-gitmodules-file
  (expand-file-name ".gitmodules" borg-top-level-directory)
  "The \".gitmodules\" file of the drone repository.")

(defvar borg-emacs-arguments '("-Q")
  "Arguments used when calling an inferior Emacs instance.
Set this in \"~/.emacs.d/etc/borg/config.el\" and also set
`EMACS_ARGUMENTS' in either \"~/.emacs.d/Makefile\" or
\"~/.emacs.d/etc/borg/config.mk\" to the same value")

(defvar borg-compile-function #'byte-compile-file
  "The function used to compile a library.")

(defvar borg-compile-recursively nil
  "Whether to compile recursively.

Unfortunately there are many packages that put random crap
into subdirectories.  Instead of this variable you should set
`submodule.<drone>.recursive-byte-compile' for each DRONE that
needs it.")

(defvar borg--compile-natively nil
  "Internal variable used by \"build-native\" make target.")

(defvar borg-build-shell-command nil
  "Optional command used to run shell command build steps.
This variable is documented in the manual (which see).")

(defvar borg-rewrite-urls-alist nil
  "An alist used to optionally rewrite certain URLs.
Each element has the form (ORIG . BASE).  Each URL that starts
with ORIG is rewritten to start with BASE instead.  See info
node `(borg)Using https URLs'.")

(defvar borg-default-build-step '(borg-update-autoloads
                                  borg-byte-compile
                                  )
  "Default build step of drone.
borg-update-autoloads
borg-byte-compile
borg-makeinfo
")

(defvar borg-maketexi-filename-regexp "\\`\\(%s\\|README\\).org\\'"
  "Regexp matching Org files that may be exported to Texinfo.
The name of the clone is substituted for %s.  Setting this to
nil disables the export of any Org files.")

(defvar borg-minimal-emacs-alist nil
  "Alist mapping drones to the Emacs release they depend on.
Drones that depend on an Emacs release higher than the currently
used release are automatically disabled.")

;;; Utilities

(defun borg-worktree (clone)
  "Return the top-level of the working tree of the package named CLONE."
  (expand-file-name (file-name-as-directory clone) borg-drones-directory))

(defun borg-gitdir (clone)
  "Return the Git directory of the package named CLONE.

Always return `<borg-user-emacs-directory>/.git/modules/<CLONE>',
even when this repository's Git directory is actually located
inside the working tree."
  (let* ((default-directory borg-top-level-directory)
         (super (ignore-errors
                  (car (process-lines "git" "rev-parse" "--git-dir")))))
    (if super
        (expand-file-name (concat super "/modules/" clone "/"))
      (error "Cannot locate super-repository"))))

(defvar borg--gitmodule-cache nil)

(defmacro borg-do-drones (spec &rest body)
  "Loop over drones.
Evaluate BODY with VAR bound to each drone, in turn.
Inside BODY variables set in \".gitmodules\" are cached.
Then evaluate RESULT to get return value, default nil.
\n(fn (VAR [RESULT]) BODY...)"
  (declare (indent 1))
  (let ((var (car spec))
        (result (cadr spec)))
    `(let ((borg--gitmodule-cache (borg-drones 'raw)))
       (dolist (,var borg--gitmodule-cache ,result)
         (setq ,var (car ,var))
         ,@body))))

(defun borg-get (clone variable &optional all)
  "Return the value of `submodule.CLONE.VARIABLE' in `~/.emacs.d/.gitmodules'.
If optional ALL is non-nil, then return all values as a list.
VARIABLE can be a symbol or a string."
  (let ((values (if borg--gitmodule-cache
                    (plist-get (cdr (assoc clone borg--gitmodule-cache))
                               (if (symbolp variable)
                                   variable
                                 (intern variable)))
                  (ignore-errors
                    ;; If the variable has no value then the exit code is
                    ;; non-zero, but that isn't an error as far as we are
                    ;; concerned.
                    (apply #'process-lines "git" "config"
                           "--file" borg-gitmodules-file
                           `(,@(and all (list "--get-all"))
                             ,(format "submodule.%s.%s" clone variable)))))))
    (if all values (car (last values)))))

(defun borg-get-all (clone variable)
  "Return all values of `submodule.CLONE.VARIABLE' in `~/.emacs.d/.gitmodules'.
Return the values as a list.  VARIABLE can be a symbol or
a string."
  (borg-get clone variable t))

(defun borg-load-path (clone)
  "Return the `load-path' for the clone named CLONE."
  (let ((repo (borg-worktree clone))
        (path (borg-get-all clone "load-path")))
    (if  path
        (mapcar (lambda (d) (expand-file-name d repo)) path)
      (let ((elisp (expand-file-name "elisp" repo))
            (lisp (expand-file-name "lisp" repo)))
        (list (cond ((file-exists-p elisp) elisp)
                    ((file-exists-p lisp) lisp)
                    (t repo)))))))

(defun borg-info-path (clone &optional setup)
  "Return the `Info-directory-list' for the clone named CLONE.

If optional SETUP is non-nil, then return a list of directories
containing org, texinfo and/or info files.  Otherwise return a
list of directories containing a file named \"dir\"."
  (let ((repo (borg-worktree clone))
        (path (borg-get-all clone "info-path")))
    (cl-mapcan
     (if setup
         (lambda (d)
           (setq d (file-name-as-directory d))
           (and (file-directory-p d)
                (directory-files
                 d t "\\.\\(org\\|texi\\(nfo\\)?\\|info\\)\\'" t)
                (list d)))
       (lambda (d)
         (setq d (file-name-as-directory d))
         (and (file-exists-p (expand-file-name "dir" d))
              (list d))))
     (if path
         (mapcar (lambda (d) (expand-file-name d repo)) path)
       (list repo
             (expand-file-name "doc" repo)
             (expand-file-name "docs" repo))))))

(defvar borg--multi-value-variables
  '(build-step load-path no-byte-compile info-path)
  "List of submodule variables which can have multiple values.")

(defun borg-dronep (name)
  "Return non-nil if a drone named NAME exists.
If set in \".gitmodules\", then return the value
of `submodule.NAME.path', nil otherwise."
  (let ((default-directory borg-top-level-directory))
    (car (process-lines "git" "submodule--helper" "config"
                        (format "submodule.%s.path" name)))))

(defun borg-drones (&optional include-variables)
  "Return a list of all assimilated drones.

The returned value is a list of the names of the assimilated
drones, unless optional INCLUDE-VARIABLES is non-nil, in which
case elements of the returned list have the form (NAME . PLIST).

PLIST is a list of paired elements.  Property names are symbols
and correspond to a VARIABLE defined in the Borg repository's
\".gitmodules\" file as \"submodule.NAME.VARIABLE\".

Each property value is either a string or a list of strings.  If
INCLUDE-VARIABLES is `raw' then all values are lists.  Otherwise
a property value is only a list if the corresponding property
name is a member of `borg--multi-value-variables'.  If a property
name isn't a member of `borg--multi-value-variables' but it does
have multiple values anyway, then the last value is included in
the overall return value."
  (let* ((default-directory borg-top-level-directory)
         (prefix (file-relative-name borg-drones-directory)))
    (if include-variables
        (let (alist)
          (dolist (line (and (file-exists-p borg-gitmodules-file)
                             (process-lines "git" "config" "--list"
                                            "--file" borg-gitmodules-file)))
            (when (string-match
                   "\\`submodule\\.\\([^.]+\\)\\.\\([^=]+\\)=\\(.+\\)\\'"
                   line)
              (let* ((drone (match-string 1 line))
                     (prop  (intern (match-string 2 line)))
                     (value (match-string 3 line))
                     (elt   (assoc drone alist))
                     (plist (cdr elt)))
                (unless elt
                  (push (setq elt (list drone)) alist))
                (setq plist (plist-put
                             plist prop
                             (if (or (eq include-variables 'raw)
                                     (memq prop borg--multi-value-variables))
                                 (nconc (plist-get plist prop)
                                        (list value))
                               value)))
                (setcdr elt plist))))
          (cl-sort (cl-delete-if-not
                    (lambda (drone)
                      (let ((path (plist-get (cdr drone) 'path)))
                        (string-prefix-p prefix
                                         (if (listp path)
                                             (car (last path))
                                           path))))
                    alist)
                   #'string< :key #'car))
      (let ((offset (+ (length prefix) 50)))
        (cl-mapcan (lambda (line)
                     (and (ignore-errors
                            (string-equal (substring line 50 offset) prefix))
                          (list (substring line offset))))
                   (process-lines "git" "submodule--helper" "list"))))))

(defun borg-clones ()
  "Return a list of cloned packages.

The returned value includes the names of all packages that were
cloned into `borg-drones-directory', including clones that have
not been assimilated yet."
  (cl-mapcan (lambda (file)
               (and (file-directory-p file)
                    (list (file-name-nondirectory file))))
             (directory-files borg-drones-directory t "\\`[^.]")))

(defun borg-read-package (prompt &optional edit-url)
  "Read a package name and URL, and return them as a list.

If the `epkg' package is available, then read a package name
in the minibuffer and use the URL stored in the Epkg database.

Otherwise if `epkg' is unavailable, the package is unknown,
or when EDIT-URL is non-nil, then also read the URL in the
minibuffer.

PROMPT is used when reading the package name.

Return a list of the form (NAME URL).  Unless the URL was
explicitly provided by the user, it may be modified according
to variable `borg-rewrite-urls-alist' (which see)."
  (if (require 'epkg nil t)
      (let* ((name (completing-read prompt (epkgs 'name)
                                    nil nil nil 'epkg-package-history))
             (pkg  (epkg name))
             (url  (and pkg
                        (with-no-warnings
                          (if (or (epkg-git-package-p pkg)
                                  (epkg-github-package-p pkg)
                                  (epkg-orphaned-package-p pkg)
                                  (epkg-gitlab-package-p pkg))
                              (eieio-oref pkg 'url)
                            (eieio-oref pkg 'mirror-url))))))
        (when url
          (pcase-dolist (`(,orig . ,base) borg-rewrite-urls-alist)
            (when (string-prefix-p orig url)
              (setq url (concat base (substring url (length orig)))))))
        (list name
              (if (or (not url) edit-url)
                  (read-string
                   "Url: "
                   (or url
                       (and (require 'magit nil t)
                            (magit-get "remote"
                                       (magit-get-some-remote) "url"))))
                url)))
    (list (read-string prompt)
          (read-string "Url: "))))

(defun borg-read-clone (prompt)
  "Read the name of a cloned package, prompting with PROMPT."
  (require 'epkg nil t)
  (completing-read prompt (borg-clones) nil t nil 'epkg-package-history))

(defmacro borg-silencio (regexp &rest body)
  "Execute the forms in BODY while silencing messages that don't match REGEXP."
  (declare (indent 1))
  (let ((msg (make-symbol "msg")))
    `(let ((,msg (symbol-function 'message)))
       (cl-letf (((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (unless (string-match-p ,regexp format-string)
                      (apply ,msg format-string args)))))
         ,@body))))

;;; Activation

(defun borg-initialize ()
  "Initialize assimilated drones.

For each drone use `borg-activate' to add the appropriate
directories to the `load-path' and `Info-directory-alist', and
load the autoloads file, if it exists.

If the value of a Git variable named `submodule.DRONE.disabled'
is true in \"~/.emacs.d/.gitmodules\", then the drone named DRONE
is skipped.

If Emacs is running without an interactive terminal, then first
load \"`borg-user-emacs-directory'/etc/borg/init.el\", if that
exists."
  (when noninteractive
    (let ((init (convert-standard-filename
                 (expand-file-name "etc/borg/init.el"
                                   borg-user-emacs-directory))))
      (when (file-exists-p init)
        (load-file init))))
  (info-initialize)
  (let ((start (current-time))
        (skipped 0)
        (initialized 0))
    (borg-do-drones (drone)
      (cond
       ((equal (borg-get drone "disabled") "true")
        (cl-incf skipped))
       ((not (file-exists-p (borg-worktree drone)))
        (cl-incf skipped))
       (t
        (cl-incf initialized)
        (borg-activate drone))))
    (let* ((message (current-message))
           (inhibit (and message
                         (string-match-p
                          "\\`Recompiling .+init\\.el\\.\\.\\.\\'" message))))
      (let ((inhibit-message inhibit))
        (message "Initializing drones...done (%s drones in %.3fs%s)"
                 initialized
                 (float-time (time-subtract (current-time) start))
                 (if (> skipped 0)
                     (format ", %d skipped" skipped)
                   "")))
      (when inhibit
        (let ((message-log-max nil))
          (message "%s" message))))))

(defun borg-activate (clone)
  "Activate the clone named CLONE.

Add the appropriate directories to `load-path' and
`Info-directory-list', and load the autoloads file,
if it exists."
  (interactive (list (borg-read-clone "Activate clone: ")))
  (cl-flet
      ((activate (dir part)
         (let ((file (expand-file-name (format "%s-%s.el" clone part) dir)))
           (and (file-exists-p file)
                (with-demoted-errors "Error loading autoloads: %s"
                  (load file nil t))
                ;; We cannot rely on the autoloads file doing that.
                (add-to-list 'load-path dir)))))
    (dolist (dir (borg-load-path clone))
      (or (activate dir "autoloads")
          (activate dir "loaddefs")       ; `org' uses a different name.
          (add-to-list 'load-path dir)))) ; There might be no autoloads file.
  (dolist (dir (borg-info-path clone))
    (push  dir Info-directory-list)))

;;; Construction

(defun borg-batch-rebuild (&optional quick native)
  "Rebuild all assimilated drones.

Borg and Compat are rebuild first, followed by other drones in
alphabetic order.  `init.el' and `USER-REAL-LOGIN-NAME.el' are
also rebuilt.

This function is to be used only with `--batch'.

When optional QUICK is non-nil, then do not build drones for
which `submodule.DRONE.build-step' is set, assuming those are
the drones that take longer to be built.

When optional NATIVE is non-nil, then compile natively.  If
NATIVE is a function, then use that, `native-compile' otherwise."
  (unless noninteractive
    (error "borg-batch-rebuild is to be used only with --batch"))
  (borg-do-drones (drone)
    (unless (and quick (borg-get-all drone "build-step"))
      (borg--remove-autoloads drone quick)))
  (when (borg-dronep "org")
    ;; `org-loaddefs.el' has to exist when compiling a library
    ;; which depends on `org', else we get warnings about that
    ;; not being so.
    (let ((default-directory (borg-worktree "org")))
      (shell-command "make autoloads")))
  ;; Building `borg' first isn't strictly necessary, but since we have
  ;; to build compat out of order, we might as well do it for borg too.
  (message "\n--- [borg] ---\n")
  (borg-build "borg")
  ;; `compat' has to be build before the first package that depends on
  ;; it is loaded.  Otherwise we would get errors about the fact that
  ;; lib/<package(sic)>/compat-24.el does not exist, which is expected
  ;; and correct, but also fatal.
  (when (borg-dronep "compat")
    (message "\n--- [compat] ---\n")
    (borg-build "compat"))
  (borg-do-drones (drone)
    (unless (member drone '("borg" "compat"))
      (message "\n--- [%s] ---\n" drone)
      (cond
       ((equal (borg-get drone "disabled") "true")
        (message "Skipped (Disabled)"))
       ((let ((min (cdr (assoc drone borg-minimal-emacs-alist))))
          (and min (version< emacs-version min)
               (message "Skipped (Requires Emacs >= %s)" min))))
       ((not (file-exists-p (borg-worktree drone)))
        (message "Skipped (Missing)"))
       ((and quick (borg-get-all drone "build-step"))
        (message "Skipped (Expensive to build)"))
       (t (let ((borg--compile-natively native))
            (borg-build drone))))))
  (borg-batch-rebuild-init))

(defun borg-batch-rebuild-init ()
  "Rebuild `init.el' and `USER-REAL-LOGIN-NAME.el'.

This function is to be used only with `--batch'."
  (unless noninteractive
    (error "borg-batch-recompile-init is to be used only with --batch"))
  (borg-silencio "\\`%s\\.\\.\\.\\(done\\)?" ; silence use-package
    (let ((default-directory borg-user-emacs-directory))
      (dolist (file (or command-line-args-left
                        (list "init.el"
                              (concat (user-real-login-name) ".el"))))
        (when (file-exists-p file)
          (message "\n--- [%s] ---\n" file)
          (load-file file)
          (byte-recompile-file (expand-file-name file) t 0))))))

(defun borg-build (clone &optional activate)
  "Build the clone named CLONE.
Interactively, or when optional ACTIVATE is non-nil,
then also activate the clone using `borg-activate'."
  (interactive (list (borg-read-clone "Build drone: ") t))
  (cond
   (noninteractive
    (when (string-suffix-p "/" clone)
      (setq clone (substring clone 0 -1)))
    (borg--build-noninteractive clone))
   ((borg--build-interactive clone)))
  (when activate
    (borg-activate clone)))

(defun borg--build-noninteractive (clone)
  (let ((default-directory (borg-worktree clone))
        (build-cmd (if (functionp borg-build-shell-command)
                       (funcall borg-build-shell-command clone)
                     borg-build-shell-command))
        (build (borg-get-all clone "build-step"))
        (config (borg--config-file)))
    (when (file-exists-p config)
      (message "  Loading %s..." config)
      (load config nil t t))
    (when (featurep 'comp)
      (when borg--compile-natively
        (setq borg-compile-function
              (if (functionp borg--compile-natively)
                  borg--compile-natively
                #'borg--native-compile)))
      (when (eq borg-compile-function 'native-compile) ; don't #'quote
        (setq borg-compile-function #'borg--native-compile)))
    (if build
        (dolist (cmd build)
          (message "  Running `%s'..." cmd)
          (cond ((member cmd '("borg-update-autoloads"
                               "borg-compile"
                               "borg-maketexi"
                               "borg-makeinfo"
                               ;; For backward compatibility.
                               "borg-byte-compile"))
                 (funcall (intern cmd) clone))
                ((string-prefix-p "(" cmd)
                 (eval (read cmd)))
                (build-cmd
                 (when (or (stringp build-cmd)
                           (setq build-cmd (funcall build-cmd clone cmd)))
                   (require 'format-spec)
                   (shell-command
                    (format-spec build-cmd
                                 `((?s . ,cmd)
                                   (?S . ,(shell-quote-argument cmd)))))))
                (t
                 (shell-command cmd)))
          (message "  Running `%s'...done" cmd))
      (let ((path (mapcar #'file-name-as-directory (borg-load-path clone))))
        (when (memq 'borg-update-autoloads borg-default-build-step)
          (borg-update-autoloads clone path))
        (when (memq 'borg-byte-compile borg-default-build-step)
          (borg-byte-compile clone path))
        (when (memq 'borg-makeinfo borg-default-build-step)
          (borg-makeinfo clone))))))

(defun borg--build-interactive (clone)
  (save-some-buffers
   nil (let ((top default-directory))
         (lambda ()
           (let ((file (buffer-file-name)))
             (and file
                  (string-match-p emacs-lisp-file-regexp file)
                  (file-in-directory-p file top))))))
  (let ((buffer (get-buffer-create "*Borg Build*"))
        (config (borg--config-file))
        (process-connection-type nil))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (setq default-directory borg-user-emacs-directory)
      (borg-build-mode)
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (when (file-exists-p config)
          (insert (format "\n(%s) Loading %s\n\n"
                          (format-time-string "%H:%M:%S")
                          config))
          (load-file config))
        (unless (looking-back "\n\n" (- (point) 2))
          (insert ?\n))
        (insert (format "(%s) Building %s\n\n"
                        (format-time-string "%H:%M:%S")
                        clone))))
    (set-process-filter
     (apply #'start-process
            (format "emacs ... --eval (borg-build %S)" clone)
            buffer
            (expand-file-name invocation-name invocation-directory)
            `("--batch" ,@borg-emacs-arguments
              "-L" ,(file-name-directory (locate-library "borg"))
              "--eval" ,(if (featurep 'borg-elpa)
                            (format "(progn
  (setq user-emacs-directory %S)
  (require 'package)
  (package-initialize 'no-activate)
  (package-activate 'borg)
  (require 'borg-elpa)
  (borg-elpa-initialize)
  (setq borg-build-shell-command (quote %S))
  (borg-build %S))" borg-user-emacs-directory borg-build-shell-command clone)
                          (format "(progn
  (require 'borg)
  (borg-initialize)
  (setq borg-build-shell-command (quote %S))
  (borg-build %S))" borg-build-shell-command clone))))
     'borg--build-process-filter)))

(defun borg--build-process-filter (process string)
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((moving (= (point) (process-mark process))))
        (save-excursion
          (goto-char (process-mark process))
          (let ((inhibit-read-only t))
            (insert string))
          (set-marker (process-mark process) (point)))
        (if moving (goto-char (process-mark process)))))))

(defvar borg-build-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-q" #'bury-buffer)
    map)
  "Keymap for `borg-build-mode'.")

(defvar borg-build-mode-lighter "Borg-Build")

(define-derived-mode borg-build-mode compilation-mode
  'borg-build-mode-lighter
  "Mode for the \"*Borg Build*\" buffer."
  (setq mode-line-process
        '((:propertize ":%s" face compilation-mode-line-run)
          compilation-mode-line-errors))
  (setq font-lock-defaults '(borg-build-mode-font-lock-keywords t)))

(defun borg-build-mode-font-lock-keywords ()
  (append '((compilation--ensure-parse))
          (remove '(" --?o\\(?:utfile\\|utput\\)?[= ]\\(\\S +\\)" . 1)
                  compilation-mode-font-lock-keywords)))

(defun borg-update-autoloads (clone &optional path)
  "Update autoload files for the clone named CLONE in the directories in PATH."
  (setq path (borg--expand-load-path clone path))
  (let ((autoload-excludes
         (nconc (mapcar #'expand-file-name
                        (borg-get-all clone "no-byte-compile"))
                (cl-mapcan
                 (lambda (dir)
                   (list (expand-file-name (concat clone "-pkg.el") dir)
                         (expand-file-name (concat clone "-test.el") dir)
                         (expand-file-name (concat clone "-tests.el") dir)))
                 path)
                autoload-excludes))
        (file (expand-file-name (format "%s-autoloads.el" clone) (car path))))
    (message " Creating %s..." file)
    ;; Stay close to what `package-generate-autoloads' does.
    (let (;; This currently defaults to `nil' anyway and there is no
          ;; need to double down on that.  By not doing so we avoid
          ;; a warning on Emacs 25 and we keep it possible for users
          ;; to change the value.
          ;; (autoload-timestamps nil)
          (backup-inhibited t)
          ;; On Emacs 25 we get "Making version-control local to
          ;; borg-autoloads.el while let-bound!" warnings, which
          ;; I believe are harmless.
          (version-control 'never)
          (noninteractive t)
          ;; I don't want to see the resulting warning again.
          (autoload-compute-prefixes
           (and (not (equal clone "ht")) autoload-compute-prefixes)))
      (with-temp-buffer ; Kludge for #128.
        (let ((coding-system-for-write 'utf-8-emacs-unix))
          (write-region (autoload-rubric file "package" nil)
                        nil file nil 'silent)))
      (cl-letf (((symbol-function 'progress-reporter-do-update) (lambda (&rest _)))
                ((symbol-function 'progress-reporter-done) (lambda (_))))
        (let ((generated-autoload-file file))
          (apply 'update-directory-autoloads path))))
    (when-let ((buf (find-buffer-visiting file)))
      (kill-buffer buf))))

(defun borg-compile (clone &optional path)
  "Compile libraries for the clone named CLONE in the directories in PATH."
  (let ((dirs (borg--expand-load-path clone path))
        (exclude (borg-get-all clone "no-byte-compile"))
        (topdir (borg-worktree clone))
        (default-directory     borg-user-emacs-directory)
        (byte-compile-root-dir borg-user-emacs-directory)
        (skip-count 0)
        (fail-count 0)
        (file-count 0)
        (dir-count  0)
        dir last-dir)
    (displaying-byte-compile-warnings
     (while (setq dir (pop dirs))
       (dolist (file (directory-files dir t))
         (let ((file-relative (file-relative-name file topdir))
               (name (file-name-nondirectory file)))
           (if (file-directory-p file)
               (when (and (if-let ((v (borg-get
                                       clone "recursive-byte-compile")))
                              (member v '("yes" "on" "true" "1"))
                            borg-compile-recursively)
                          (not (file-symlink-p file))
                          (not (string-prefix-p "." name))
                          (not (member name '("RCS" "CVS"))))
                 (if (or (file-exists-p (expand-file-name ".nosearch" file))
                         (member file-relative exclude))
                     (message " Skipping %s...skipped" file)
                   (setq dirs (nconc dirs (list file)))))
             (when (and (file-regular-p  file)
                        (file-readable-p file)
                        (string-match-p emacs-lisp-file-regexp name)
                        (not (auto-save-file-name-p file))
                        (not (string-prefix-p "." name))
                        (not (string-suffix-p "-autoloads.el" name))
                        (not (string-equal dir-locals-file name)))
               (cl-incf
                (if (or (string-suffix-p "-pkg.el" name)
                        (string-suffix-p "-test.el" name)
                        (string-suffix-p "-tests.el" name)
                        (member file-relative exclude))
                    (progn (message " Skipping %s...skipped" file)
                           skip-count)
                  (unless byte-compile-verbose
                    (message "Compiling %s..." file))
                  (pcase (funcall borg-compile-function file)
                    ('no-byte-compile
                     (message "Compiling %s...skipped" file)
                     skip-count)
                    ((or 't (pred stringp))
                     file-count)
                    (_ fail-count))))
               (unless (equal dir last-dir)
                 (setq last-dir dir)
                 (cl-incf dir-count))))))))
    (message "Done (Total of %d file%s compiled%s%s%s)"
             file-count (if (= file-count 1) "" "s")
             (if (> fail-count 0) (format ", %d failed"  fail-count) "")
             (if (> skip-count 0) (format ", %d skipped" skip-count) "")
             (if (> dir-count  1) (format " in %d directories" dir-count) ""))))

(defun borg-maketexi (clone &optional files)
  "Generate Texinfo manuals from Org files for the clone named CLONE.
Export each file located on `borg-info-path' if its name matches
`borg-maketexi-filename-regexp' and the `TEXINFO_DIR_HEADER'
export keyword is set in its content.  If optional FILES is
non-nil, then try those files instead.  On Emacs 25 this function
doesn't do anything."
  ;; ... because turning on `org-mode' (via `find-file-noselect')
  ;; results in an error that I do not wish to investigate.
  (when (and (> emacs-major-version 25)
             (or files borg-maketexi-filename-regexp))
    (let ((repo (borg-worktree clone))
          (exclude (borg-get-all clone "no-maketexi")))
      (dolist (file (or files
                        (cl-mapcan
                         (lambda (dir)
                           (directory-files
                            dir t (format borg-maketexi-filename-regexp clone)))
                         (borg-info-path clone t))))
        (unless (or (member (file-relative-name file repo) exclude)
                    (borg--file-tracked-p
                     (concat (file-name-sans-extension file) ".texi")))
          (let ((buffer (get-file-buffer file)))
            (with-current-buffer (or buffer (find-file-noselect file))
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char (point-min))
                  (when (save-excursion
                          (let ((case-fold-search t))
                            (re-search-forward
                             "^#\\+texinfo_dir_title:" nil t)))
                    (let ((export
                           (save-excursion
                             (let ((case-fold-search t))
                               (and (re-search-forward
                                     "^#\\+export_file_name:\\(.+\\)" nil t)
                                    (string-trim (match-string 1)))))))
                      (unless (and export
                                   (member (file-name-extension export)
                                           '("texi" "texinfo"))
                                   (borg--file-tracked-p export))
                        (message "Exporting %s..." file)
                        (require (quote ox))
                        (ignore-errors (org-texinfo-export-to-texinfo))
                        (message "Exporting %s...done" file))))))
              (unless buffer
                (kill-buffer (current-buffer))))))))))

(defun borg-makeinfo (clone)
  "Generate Info manuals and the Info index for the clone named CLONE."
  (dolist (default-directory (borg-info-path clone t))
    (let ((exclude (nconc (list "fdl.texi" "gpl.texi")
                          (borg-get-all clone "no-makeinfo"))))
      (dolist (texi (directory-files default-directory nil
                                     "\\.texi\\(nfo\\)?\\'"))
        (let ((info (concat (file-name-sans-extension texi) ".info")))
          (unless (or (member texi exclude)
                      (borg--file-tracked-p info))
            (let ((cmd (format "makeinfo --no-split %s -o %s" texi info)))
              (message "  Running `%s'..." cmd)
              (borg-silencio "\\`(Shell command succeeded with %s)\\'"
                (shell-command cmd))
              (message "  Running `%s'...done" cmd))))))
    (dolist (info (directory-files default-directory nil "\\.info\\'"))
      (let ((cmd (format "install-info %s --dir=dir" info)))
        (message "  Running `%s'..." cmd)
        (borg-silencio "\\`(Shell command succeeded with %s)\\'"
          (shell-command cmd))
        (message "  Running `%s'...done" cmd)))))

(defun borg--remove-autoloads (drone &optional quick)
  (unless (or (equal (borg-get drone "disabled") "true")
              (not (file-exists-p (borg-worktree drone)))
              (and quick (borg-get-all drone "build-step")))
    (dolist (dir (borg-load-path drone))
      (dolist (file (directory-files
                     dir t "\\(\\.elc\\|-autoloads\\.el\\|-loaddefs\\.el\\)\\'"
                     t))
        (ignore-errors (delete-file file))))))

(defun borg--native-compile (file)
  (with-demoted-errors "borg--native-compile: %S"
    (when (fboundp 'native-compile)
      (native-compile file))))

;;; Assimilation

(defun borg-assimilate (package url &optional partially)
  "Assimilate the package named PACKAGE from URL.

If `epkg' is available, then only read the name of the package
in the minibuffer and use the url stored in the Epkg database.
If `epkg' is unavailable, the package is not in the database, or
with a prefix argument, then also read the url in the minibuffer.

With a negative prefix argument only add the submodule but don't
build and activate the drone."
  (interactive
   (nconc (borg-read-package "Assimilate package: " current-prefix-arg)
          (list (< (prefix-numeric-value current-prefix-arg) 0))))
  ;; (borg--maybe-confirm-unsafe-action "assimilate" package url)
  (message "Assimilating %s..." package)
  (let ((default-directory borg-top-level-directory))
    (borg--maybe-reuse-gitdir package)
    (borg--call-git package "submodule" "add" "--name" package url
                    (file-relative-name (borg-worktree package)))
    (borg--sort-submodule-sections ".gitmodules")
    (borg--call-git package "add" ".gitmodules")
    (borg--maybe-absorb-gitdir package))
  (unless partially
    (borg-build package)
    (borg-activate package))
  (borg--refresh-magit)
  (message "Assimilating %s...done" package))

(defun borg-clone (package url)
  "Clone the package named PACKAGE from URL, without assimilating it.

If `epkg' is available, then only read the name of the package
in the minibuffer and use the url stored in the Epkg database.
If `epkg' is unavailable, the package is not in the database, or
with a prefix argument, then also read the url in the minibuffer."
  (interactive (borg-read-package "Clone package: " current-prefix-arg))
  (borg--maybe-confirm-unsafe-action "clone" package url)
  (message "Cloning %s..." package)
  (let ((gitdir (borg-gitdir package))
        (topdir (borg-worktree package)))
    (when (file-exists-p topdir)
      (user-error "%s already exists" topdir))
    (let ((default-directory borg-top-level-directory))
      (borg--maybe-reuse-gitdir package)
      (unless (file-exists-p topdir)
        (borg--call-git package "clone"
                        (concat "--separate-git-dir="
                                ;; Git fails if this ends with slash.
                                (directory-file-name gitdir))
                        url (file-relative-name topdir)))
      (borg--link-gitdir package))
    (borg--refresh-magit)
    (message "Cloning %s...done" package)))

(defun borg-remove (clone)
  "Remove the cloned or assimilated package named CLONE.

Remove the working tree from `borg-drones-directory', regardless
of whether that repository belongs to an assimilated package or a
package that has only been cloned for review using `borg-clone'.
The Git directory is not removed."
  (interactive (list (borg-read-clone "Uninstall clone: ")))
  (message "Removing %s..." clone)
  (let ((topdir (borg-worktree clone)))
    (let ((default-directory topdir))
      (when (or (not (borg--git-success "diff" "--quiet" "--cached"))
                (not (borg--git-success "diff" "--quiet")))
        (user-error "%s contains uncommitted changes" topdir))
      (borg--maybe-absorb-gitdir clone))
    (if (member clone (borg-drones))
        (let ((default-directory borg-top-level-directory))
          (borg--call-git nil "rm" "--force" (file-relative-name topdir)))
      (delete-directory topdir t t)))
  (borg--refresh-magit)
  (message "Removing %s...done" clone))

;;; Convenience

(with-eval-after-load 'git-commit
  (define-key git-commit-mode-map "\C-c\C-b" #'borg-insert-update-message))

(defun borg-insert-update-message ()
  "Insert information about drones that are changed in the index.
Formatting is according to the commit message conventions."
  (interactive)
  (when-let ((alist (borg--drone-states)))
    (let ((width (apply #'max (mapcar (lambda (e) (length (car e))) alist)))
          (align (cl-member-if (pcase-lambda (`(,_ ,_ ,version))
                                 (and version
                                      (string-match-p "\\`v[0-9]" version)))
                               alist)))
      (when (> (length alist) 1)
        (let ((a 0) (m 0) (d 0))
          (pcase-dolist (`(,_ ,state ,_) alist)
            (pcase state
              ("A" (cl-incf a))
              ("M" (cl-incf m))
              ("D" (cl-incf d))))
          (insert (format "%s %-s drones\n\n"
                          (pcase (list a m d)
                            (`(,_ 0 0) "Assimilate")
                            (`(0 ,_ 0) "Update")
                            (`(0 0 ,_) "Remove")
                            (_         "CHANGE"))
                          (length alist)))))
      (pcase-dolist (`(,drone ,state ,version) alist)
        (insert
         (format
          (pcase state
            ("A" (format "Assimilate %%-%is %%s%%s\n" width))
            ("M" (format "Update %%-%is to %%s%%s\n" width))
            ("D" "Remove %s\n"))
          drone
          (if (and align version
                   (string-match-p "\\`\\([0-9]\\|[0-9a-f]\\{7\\}\\)" version))
              " "
            "")
          version))))))

(defun borg--drone-states ()
  (let ((default-directory borg-user-emacs-directory))
    (mapcar
     (lambda (line)
       (pcase-let ((`(,state ,module) (split-string line "\t")))
         (list (file-name-nondirectory module)
               state
               (and (member state '("A" "M"))
                    (let ((default-directory (expand-file-name module)))
                      (if (file-directory-p default-directory)
                          (car (process-lines
                                "git" "describe" "--tags" "--always"))
                        "REMOVED"))))))
     (process-lines "git" "diff-index" "--name-status" "--cached" "HEAD"
                    "--" (file-relative-name borg-drones-directory)))))

;;; Internal Utilities

(defun borg--config-file ()
  (convert-standard-filename
   (expand-file-name "etc/borg/config.el" borg-user-emacs-directory)))

(defun borg--maybe-absorb-gitdir (pkg)
  (let* ((ver (nth 2 (split-string (car (process-lines "git" "version")) " ")))
         (ver (and (string-match "\\`[0-9]+\\(\\.[0-9]+\\)*" ver)
                   (match-string 0 ver))))
    (if (version< ver "2.12.0")
        (let ((default-directory (borg-worktree pkg))
              (gitdir (borg-gitdir pkg)))
          (make-directory gitdir t)
          (borg--call-git pkg "init" "--separate-git-dir" gitdir)
          (borg--link-gitdir pkg))
      (borg--call-git pkg "submodule" "absorbgitdirs" "--" (borg-worktree pkg)))))

(defun borg--maybe-reuse-gitdir (pkg)
  (let ((gitdir (borg-gitdir pkg))
        (topdir (borg-worktree pkg)))
    (when (and (file-exists-p gitdir)
               (not (file-exists-p topdir)))
      (pcase (read-char-choice
              (concat
               gitdir " already exists.\n"
               "Type [r] to reuse the existing gitdir and create the worktree\n"
               "     [d] to delete the old gitdir and clone again\n"
               "   [C-g] to abort ")
              '(?r ?d))
        (?r (borg--restore-worktree pkg))
        (?d (delete-directory gitdir t t))))))

(defun borg--restore-worktree (pkg)
  (let ((topdir (borg-worktree pkg)))
    (make-directory topdir t)
    (borg--link-gitdir pkg)
    (let ((default-directory topdir))
      (borg--call-git pkg "reset" "--hard" "HEAD"))))

(defun borg--link-gitdir (pkg)
  (let ((gitdir (borg-gitdir pkg))
        (topdir (borg-worktree pkg)))
    (with-temp-file (expand-file-name ".git" topdir)
      (insert "gitdir: " (file-relative-name gitdir topdir) "\n"))))

(defun borg--call-git (pkg &rest args)
  (let ((process-connection-type nil)
        (buffer (generate-new-buffer
                 (concat " *Borg Git" (and pkg (concat " " pkg)) "*"))))
    (if (eq (apply #'call-process "git" nil buffer nil args) 0)
        (kill-buffer buffer)
      (with-current-buffer buffer
        (special-mode))
      (pop-to-buffer buffer)
      (error "Git failed"))))

(defun borg--git-success (&rest args)
  (= (apply #'process-file "git" nil nil nil args) 0))

(defun borg--file-tracked-p (file)
  (borg--git-success "ls-files" "--error-unmatch" file))

(defun borg--refresh-magit ()
  (when (and (derived-mode-p 'magit-mode)
             (fboundp 'magit-refresh))
    (magit-refresh)))

(defun borg--expand-load-path (clone path)
  (let ((default-directory (borg-worktree clone)))
    (mapcar (lambda (p)
              (file-name-as-directory (expand-file-name p)))
            (or path (borg-load-path clone)))))

(defun borg--sort-submodule-sections (file)
  "Sort submodule sections in the current buffer.
Non-interactively operate in FILE instead."
  (interactive (list buffer-file-name))
  (with-current-buffer (or (find-buffer-visiting file)
                           (find-file-noselect file))
    (revert-buffer t t)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\[submodule" nil t)
        (let ((end (or (and (save-excursion (re-search-forward "^##+ ." nil t))
                            (match-beginning 0))
                       (point-max))))
          (sort-regexp-fields
           nil
           "^\\(?:#.*\n\\)*\\[submodule \"\\([^\"]+\\)\"].*\\(?:[^[].*\n\\)+"
           "\\1" (line-beginning-position) end)
          (goto-char end))))
    (save-buffer)))

(defun borg--maybe-confirm-unsafe-action (action package url)
  (require 'epkg nil t)
  (let* ((pkg (and (fboundp 'epkg)
                   (epkg package)))
         (ask (cond ((and (fboundp 'epkg-wiki-package-p)
                          (epkg-wiki-package-p pkg))
                     "\
This package is from the Emacswiki.  Anyone could trivially \
inject malicious code.  Do you really want to %s it? ")
                    ((or (and (fboundp 'epkg-orphaned-package-p)
                              (epkg-orphaned-package-p pkg))
                         (string-match-p "emacsorphanage" url))
                     "\
This package is from the Emacsorphanage, which might import it \
over an insecure connection.  Do you really want to %s it? ")
                    ((or (and (fboundp 'epkg-shelved-package-p)
                              (epkg-shelved-package-p pkg))
                         (string-match-p "emacsattic" url))
                     "\
This package is from the Emacsattic, which might have imported it \
over an insecure connection.  Do you really want to %s it? ")
                    ((or (string-prefix-p "git://" url)
                         (string-prefix-p "http://" url))
                     "\
This package is being fetched over an insecure connection. \
Do you really want to %s it? "))))
    (when (and ask (not (yes-or-no-p (format ask action))))
      (user-error "Abort"))))

;;; _
(provide 'borg)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; borg.el ends here
