;;; helm-async.el --- Copy/move/delete asynchronously in dired/helm.

;; Copyright (C) 2012 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Created: 14 Jun 2012
;; Version: 1.0
;; Keywords: dired async network
;; X-URL: https://github.com/jwiegley/helm-async

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; The function, which must be loaded *after* dired-aux.el, performs copies,
;; moves and all what is handled by `dired-create-file' in the background
;; using a slave Emacs process, by means of the async.el module.
;; To use it, put this in your .emacs:
;;
;;   (eval-after-load "dired-aux"
;;     '(require 'helm-async))

;;; Code:

(eval-when-compile (require 'cl)) ; for declare
(require 'dired-aux)
(require 'async)

(eval-when-compile
  (defvar async-callback))
(defvar helm-async-operation nil)

(defgroup helm-async nil
  "Copy rename files asynchronously from helm or dired."
  :group 'helm)

(defcustom helm-async-env-variables-regexp
  "\\`\\(tramp-default\\|ange-ftp\\)-.*"
  "Variables matching this regexp will be loaded on Child Emacs."
  :type  'regexp
  :group 'helm-async)

(defcustom helm-async-message-function 'helm-async-mode-line-message
  "Function to use to notify result when operation finish.
Should take same args as `message'."
  :group 'helm-async
  :type  'function)

(defface helm-async-message
    '((t (:foreground "yellow")))
  "Face used for mode-line message.")

(define-minor-mode helm-async-mode
    "Notify mode-line that an async process run."
  :group 'helm-async
  :global t
  :lighter " [Async job running]")

(defun helm-async-mode-line-message (text &rest args)
  "Notify end of operation in `mode-line'."
  (message nil)
  (let ((mode-line-format (concat
                           " " (propertize
                                (if args
                                    (apply #'format text args)
                                    text)
                                'face 'helm-async-message))))
    (force-mode-line-update)
    (sit-for 3)
    (force-mode-line-update)))

(defun helm-async-after-file-create ()
  "Callback function used for operation handled by `dired-create-file'."
  (helm-async-mode -1)
  (when helm-async-operation
    (funcall helm-async-message-function "Asynchronous %s of %s file(s) done"
             (car helm-async-operation) (cadr helm-async-operation))))

(defun helm-async-maybe-kill-ftp ()
  "Return a form to kill ftp process in child emacs."
  (quote
   (progn
     (require 'cl)
     (let ((buf (loop for b in (buffer-list)
                      thereis (and (string-match
                                    "\\`\\*ftp.*"
                                    (buffer-name b)) b))))
       (when buf (kill-buffer buf))))))

(defun dired-create-files (file-creator operation fn-list name-constructor
                                        &optional marker-char)
  "Create one or more new files from a list of existing files FN-LIST.
This function also handles querying the user, updating Dired
buffers, and displaying a success or failure message.

FILE-CREATOR should be a function.  It is called once for each
file in FN-LIST, and must create a new file, querying the user
and updating Dired buffers as necessary.  It should accept three
arguments: the old file name, the new name, and an argument
OK-IF-ALREADY-EXISTS with the same meaning as in `copy-file'.

OPERATION should be a capitalized string describing the operation
performed (e.g. `Copy').  It is used for error logging.

FN-LIST is the list of files to copy (full absolute file names).

NAME-CONSTRUCTOR should be a function accepting a single
argument, the name of an old file, and returning either the
corresponding new file name or nil to skip.

Optional MARKER-CHAR is a character with which to mark every
newfile's entry, or t to use the current marker character if the
old file was marked."
  (setq helm-async-operation nil)
  (let (dired-create-files-failures failures async-fn-list
        skipped (success-count 0) (total (length fn-list))
        (callback `(lambda (&optional ignore)
                     (helm-async-after-file-create))))
    (let (to overwrite-query
             overwrite-backup-query)	; for dired-handle-overwrite
      (dolist (from fn-list)
        (setq to (funcall name-constructor from))
        (if (equal to from)
            (progn
              (setq to nil)
              (dired-log "Cannot %s to same file: %s\n"
                         (downcase operation) from)))
        (if (not to)
            (setq skipped (cons (dired-make-relative from) skipped))
          (let* ((overwrite (file-exists-p to))
                 (dired-overwrite-confirmed ; for dired-handle-overwrite
                  (and overwrite
                       (let ((help-form '(format "\
Type SPC or `y' to overwrite file `%s',
DEL or `n' to skip to next,
ESC or `q' to not overwrite any of the remaining files,
`!' to overwrite all remaining files with no more questions." to)))
                         (dired-query 'overwrite-query
                                      "Overwrite `%s'?" to))))
                 ;; must determine if FROM is marked before file-creator
                 ;; gets a chance to delete it (in case of a move).
                 (actual-marker-char
                  (cond  ((integerp marker-char) marker-char)
                         (marker-char (dired-file-marker from)) ; slow
                         (t nil))))
            ;; Handle the `dired-copy-file' file-creator specially
            ;; When copying a directory to another directory or
            ;; possibly to itself or one of its subdirectories.
            ;; e.g "~/foo/" => "~/test/"
            ;; or "~/foo/" =>"~/foo/"
            ;; or "~/foo/ => ~/foo/bar/")
            ;; In this case the 'name-constructor' have set the destination
            ;; TO to "~/test/foo" because the old emacs23 behavior
            ;; of `copy-directory' was to not create the subdirectory
            ;; and instead copy the contents.
            ;; With the new behavior of `copy-directory'
            ;; (similar to the `cp' shell command) we don't
            ;; need such a construction of the target directory,
            ;; so modify the destination TO to "~/test/" instead of "~/test/foo/".
            (let ((destname (file-name-directory to)))
              (when (and (file-directory-p from)
                         (file-directory-p to)
                         (eq file-creator 'dired-copy-file))
                (setq to destname))
              ;; If DESTNAME is a subdirectory of FROM, not a symlink,
              ;; and the method in use is copying, signal an error.
              (and (eq t (car (file-attributes destname)))
                   (eq file-creator 'dired-copy-file)
                   (file-in-directory-p destname from)
                   (error "Cannot copy `%s' into its subdirectory `%s'"
                          from to)))
            (push (cons from to) async-fn-list)))))
    (async-start `(lambda ()
                    ,(async-inject-variables helm-async-env-variables-regexp)
                    (require 'cl) (require 'dired-aux)
                    (loop for (f . d) in (quote ,async-fn-list)
                          do (funcall (quote ,file-creator) f d t))
                    ,(helm-async-maybe-kill-ftp))
                 callback)
    (cond
     (dired-create-files-failures
      (setq failures (nconc failures dired-create-files-failures))
      (dired-log-summary
       (format "%s failed for %d file%s in %d requests"
                operation (length failures)
                (dired-plural-s (length failures))
                total)
       failures))
     (failures
      (dired-log-summary
       (format "%s failed for %d of %d file%s"
                operation (length failures)
                total (dired-plural-s total))
       failures))
     (skipped
      (dired-log-summary
       (format "%s: %d of %d file%s skipped"
                operation (length skipped) total
                (dired-plural-s total))
       skipped))
     (t
      (helm-async-mode 1)
      (setq helm-async-operation (list operation (length fn-list)))
      (message "%s proceeding asynchronously..." operation)))))


(provide 'helm-async)

;;; helm-async.el ends here
