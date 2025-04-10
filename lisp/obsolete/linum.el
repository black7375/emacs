;;; linum.el --- display line numbers in the left margin -*- lexical-binding: t -*-

;; Copyright (C) 2008-2025 Free Software Foundation, Inc.

;; Author: Markus Triska <markus.triska@gmx.at>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: convenience
;; Old-Version: 0.9x
;; Obsolete-since: 29.1

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; NOTE: This library was made obsolete in Emacs 29.1.  We recommend
;; using either the built-in `display-line-numbers-mode', or the
;; `nlinum' package from GNU ELPA instead.  The former has better
;; performance, but the latter is closer to a drop-in replacement.
;;
;; --------------------
;;
;; Display line numbers for the current buffer.
;;
;; Toggle display of line numbers with M-x linum-mode.  To enable
;; line numbering in all buffers, use M-x global-linum-mode.
;;
;; Consider using native line numbers instead:
;;   M-x display-line-numbers-mode

;;; Code:

(defvar-local linum-overlays nil "Overlays used in this buffer.")
(defvar-local linum-available nil "Overlays available for reuse.")
(defvar linum-before-numbering-hook nil
  "Functions run in each buffer before line numbering starts.")

(defgroup linum nil
  "Show line numbers in the left margin."
  :group 'convenience)

(defcustom linum-format 'dynamic
  "Format used to display line numbers.
Either a format string like \"%7d\", `dynamic' to adapt the width
as needed, or a function that is called with a line number as its
argument and should evaluate to a string to be shown on that line.
See also `linum-before-numbering-hook'."
  :group 'linum
  :type '(choice (string :tag "Format string")
                 (const :tag "Dynamic width" dynamic)
                 (function :tag "Function")))

(defface linum
  '((t :inherit (shadow default)))
  "Face for displaying line numbers in the display margin."
  :group 'linum)

(defcustom linum-eager t
  "Whether line numbers should be updated after each command.
The conservative setting nil might miss some buffer changes,
and you have to scroll or press \\[recenter-top-bottom] to update the numbers."
  :group 'linum
  :type 'boolean)

(defcustom linum-delay nil
  "Delay updates to give Emacs a chance for other changes."
  :group 'linum
  :type 'boolean)

;;;###autoload
(define-minor-mode linum-mode
  "Toggle display of line numbers in the left margin (Linum mode).
This mode has been largely replaced by `display-line-numbers-mode'
(which is much faster and has fewer interaction problems with other
modes).

Linum mode is a buffer-local minor mode."
  :lighter ""                           ; for desktop.el
  :append-arg-docstring t
  (if linum-mode
      (progn
        (if linum-eager
            (add-hook 'post-command-hook (if linum-delay
                                             'linum-schedule
                                           'linum-update-current) nil t)
          (add-hook 'after-change-functions 'linum-after-change nil t))
        (add-hook 'window-scroll-functions 'linum-after-scroll nil t)
        (add-hook 'change-major-mode-hook 'linum-delete-overlays nil t)
        (add-hook 'window-configuration-change-hook
                  ;; FIXME: If the buffer is shown in N windows, this
                  ;; will be called N times rather than once.  We should use
                  ;; something like linum-update-window instead.
                  'linum-update-current nil t)
        (linum-update-current))
    (remove-hook 'post-command-hook 'linum-update-current t)
    (remove-hook 'post-command-hook 'linum-schedule t)
    (remove-hook 'window-scroll-functions 'linum-after-scroll t)
    (remove-hook 'after-change-functions 'linum-after-change t)
    (remove-hook 'window-configuration-change-hook 'linum-update-current t)
    (remove-hook 'change-major-mode-hook 'linum-delete-overlays t)
    (linum-delete-overlays)))

;;;###autoload
(define-globalized-minor-mode global-linum-mode linum-mode linum-on)

(defun linum-on ()
  (unless (or (minibufferp)
              ;; Turning linum-mode in the daemon's initial frame
              ;; could significantly slow down startup, if the buffer
              ;; in which this is done is large, because Emacs thinks
              ;; the "window" spans the entire buffer then.  This
              ;; could happen when restoring session via desktop.el,
              ;; if some large buffer was under linum-mode when
              ;; desktop was saved.  So we disable linum-mode for
              ;; non-client frames in a daemon session.

              ;; Note that nowadays, this actually doesn't show line
              ;; numbers in client frames at all, because we visit the
              ;; file before creating the client frame.  See bug#35726.
              (and (daemonp) (null (frame-parameter nil 'client))))
    (linum-mode 1)))

(defun linum-delete-overlays ()
  "Delete all overlays displaying line numbers for this buffer."
  (mapc #'delete-overlay linum-overlays)
  (setq linum-overlays nil)
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    ;; restore margins if needed FIXME: This still fails if the
    ;; "other" mode has incidentally set margins to exactly what linum
    ;; had: see bug#20674 for a similar workaround in nlinum.el
    (let ((set-margins (window-parameter w 'linum--set-margins))
          (current-margins (window-margins w)))
      (when (and set-margins
                 (equal set-margins current-margins))
        (set-window-margins w 0 (cdr current-margins))
        (set-window-parameter w 'linum--set-margins nil)))))

(defun linum-update-current ()
  "Update line numbers for the current buffer."
  (linum-update (current-buffer)))

(defun linum-update (buffer)
  "Update line numbers for all windows displaying BUFFER."
  (with-current-buffer buffer
    (when linum-mode
      (setq linum-available linum-overlays)
      (setq linum-overlays nil)
      (save-excursion
        (mapc #'linum-update-window
              (get-buffer-window-list buffer nil 'visible)))
      (mapc #'delete-overlay linum-available)
      (setq linum-available nil))))

;; Behind display-graphic-p test.
(declare-function font-info "font.c" (name &optional frame))

(defun linum--face-width (face)
  (let ((info (font-info (face-font face)))
        width)
    (setq width (aref info 11))
    (if (<= width 0)
        (setq width (aref info 10)))
    width))

(defun linum-update-window (win)
  "Update line numbers for the portion visible in window WIN."
  (goto-char (window-start win))
  (let ((line (line-number-at-pos))
        (limit (window-end win t))
        (fmt (cond ((stringp linum-format) linum-format)
                   ((eq linum-format 'dynamic)
                    (let ((w (length (number-to-string
                                      (count-lines (point-min) (point-max))))))
                      (concat "%" (number-to-string w) "d")))))
        (width 0))
    (run-hooks 'linum-before-numbering-hook)
    ;; Create an overlay (or reuse an existing one) for each
    ;; line visible in this window, if necessary.
    (while (and (not (eobp)) (< (point) limit))
      (let* ((str (if fmt
                      (propertize (format fmt line) 'face 'linum)
                    (funcall linum-format line)))
             (visited (catch 'visited
                        (dolist (o (overlays-in (point) (point)))
                          (when (equal-including-properties
                                 (overlay-get o 'linum-str) str)
                            (unless (memq o linum-overlays)
                              (push o linum-overlays))
                            (setq linum-available (delq o linum-available))
                            (throw 'visited t))))))
        (setq width (max width (length str)))
        (unless visited
          (let ((ov (if (null linum-available)
                        (make-overlay (point) (point))
                      (move-overlay (pop linum-available) (point) (point)))))
            (push ov linum-overlays)
            (overlay-put ov 'before-string
                         (propertize " " 'display `((margin left-margin) ,str)))
            (overlay-put ov 'linum-str str))))
      (forward-line)
      (setq line (1+ line)))
    (when (display-graphic-p)
      (setq width (ceiling
                   (/ (* width 1.0 (linum--face-width 'linum))
                      (frame-char-width)))))
    ;; open up space in the left margin, if needed, and record that
    ;; fact as the window-parameter `linum--set-margins'
    (let ((existing-margins (window-margins win)))
      (when (> width (or (car existing-margins) 0))
        (set-window-margins win width (cdr existing-margins))
        (set-window-parameter win 'linum--set-margins (window-margins win))))))

(defun linum-after-change (beg end _len)
  ;; update overlays on deletions, and after newlines are inserted
  (when (or (= beg end)
            (= end (point-max))
            (string-search "\n" (buffer-substring-no-properties beg end)))
    (linum-update-current)))

(defun linum-after-scroll (win _start)
  (linum-update (window-buffer win)))

(defun linum-schedule ()
  ;; schedule an update; the delay gives Emacs a chance for display changes
  (run-with-idle-timer 0 nil #'linum-update-current))

(defun linum-unload-function ()
  "Unload the Linum library."
  (global-linum-mode -1)
  ;; continue standard unloading
  nil)

(defconst linum-version "0.9x")
(make-obsolete-variable 'linum-version 'emacs-version "28.1")

(make-obsolete 'linum-mode #'display-line-numbers-mode "29.1")
(make-obsolete 'global-linum-mode #'global-display-line-numbers-mode "29.1")

(provide 'linum)

;;; linum.el ends here
