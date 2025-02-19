;;; qp.el --- Quoted-Printable functions  -*- lexical-binding:t -*-

;; Copyright (C) 1998-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: mail, extensions

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

;; Functions for encoding and decoding quoted-printable text as
;; defined in RFC 2045.

;;; Code:

;;;###autoload
(defun quoted-printable-decode-region (from to &optional coding-system)
  "Decode quoted-printable in the region between FROM and TO, per RFC 2045.
If CODING-SYSTEM is non-nil, decode bytes into characters with that
coding-system.

Interactively, you can supply the CODING-SYSTEM argument
with \\[universal-coding-system-argument].

The CODING-SYSTEM argument is a historical hangover and is deprecated.
QP encodes raw bytes and should be decoded into raw bytes.  Decoding
them into characters should be done separately."
  (interactive
   ;; Let the user determine the coding system with "C-x RET c".
   (list (region-beginning) (region-end) coding-system-for-read))
  (when (and coding-system
	     (not (coding-system-p coding-system))) ; e.g. `ascii' from Gnus
    (setq coding-system nil))
  (save-excursion
    (save-restriction
      ;; RFC 2045:  ``An "=" followed by two hexadecimal digits, one
      ;; or both of which are lowercase letters in "abcdef", is
      ;; formally illegal. A robust implementation might choose to
      ;; recognize them as the corresponding uppercase letters.''
      (let ((case-fold-search t))
	(narrow-to-region from to)
	;; Do this in case we're called from Gnus, say, in a buffer
	;; which already contains non-ASCII characters which would
	;; then get doubly-decoded below.
	(if coding-system
	    (encode-coding-region (point-min) (point-max) coding-system))
	(goto-char (point-min))
	(while (and (skip-chars-forward "^=")
		    (not (eobp)))
	  (cond ((eq (char-after (1+ (point))) ?\n)
		 (delete-char 2))
		((looking-at "\\(=[0-9A-F][0-9A-F]\\)+")
		 ;; Decode this sequence at once; i.e. by a single
		 ;; deletion and insertion.
		 (let* ((n (/ (- (match-end 0) (point)) 3))
			(str (make-string n 0)))
		   (dotimes (i n)
                     (let ((n1 (char-after (1+ (point))))
                           (n2 (char-after (+ 2 (point)))))
                       (aset str i
                             (+ (* 16 (- n1 (if (<= n1 ?9) ?0
                                              (if (<= n1 ?F) (- ?A 10)
                                                (- ?a 10)))))
                                (- n2 (if (<= n2 ?9) ?0
                                        (if (<= n2 ?F) (- ?A 10)
                                          (- ?a 10)))))))
		     (forward-char 3))
		   (delete-region (match-beginning 0) (match-end 0))
		   (insert str)))
		(t
		 (message "Malformed quoted-printable text")
		 (forward-char)))))
      (if coding-system
	  (decode-coding-region (point-min) (point-max) coding-system)))))

(defun quoted-printable-decode-string (string &optional coding-system)
  "Decode the quoted-printable encoded STRING and return the result.
If CODING-SYSTEM is non-nil, decode the string with coding-system.
Use of CODING-SYSTEM is deprecated; this function should deal with
raw bytes, and coding conversion should be done separately."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert string)
    (quoted-printable-decode-region (point-min) (point-max) coding-system)
    (buffer-string)))

(defun quoted-printable-encode-region (from to &optional fold class)
  "Quoted-printable encode the region between FROM and TO per RFC 2045.

If FOLD, fold long lines at 76 characters (as required by the RFC).
If CLASS is non-nil, translate the characters not matched by that
regexp class, which is in the form expected by `skip-chars-forward'.
You should probably avoid non-ASCII characters in this arg.

If `mm-use-ultra-safe-encoding' is set, fold lines unconditionally and
encode lines starting with \"From\"."
  (interactive "r")
  (unless class
    ;; Avoid using 8bit characters. = is \075.
    ;; Equivalent to "^\000-\007\013\015-\037\200-\377="
    (setq class "\010-\012\014\040-\074\076-\177"))
  (save-excursion
    (goto-char from)
    (if (re-search-forward "[^\x0-\x7f\x80-\xff]" to t)
	(error "Multibyte character in QP encoding region"))
    (save-restriction
      (narrow-to-region from to)
      ;; Encode all the non-ascii and control characters.
      (goto-char (point-min))
      (while (and (skip-chars-forward class)
		  (not (eobp)))
	(insert
	 (prog1
	     (format "=%02X" (get-byte))
	   (delete-char 1))))
      ;; Encode white space at the end of lines.
      (goto-char (point-min))
      (while (re-search-forward "[ \t]+$" nil t)
	(goto-char (match-beginning 0))
	(while (not (eolp))
	  (insert
	   (prog1
	       (format "=%02X" (get-byte))
	     (delete-char 1)))))
      (let ((ultra
	     (and (boundp 'mm-use-ultra-safe-encoding)
		  mm-use-ultra-safe-encoding)))
	(when (or fold ultra)
	  (let ((tab-width 1)		; HTAB is one character.
		(case-fold-search nil))
	    (goto-char (point-min))
	    (while (not (eobp))
	      ;; In ultra-safe mode, encode "From " at the beginning
	      ;; of a line.
	      (when ultra
		(if (looking-at "From ")
		    (replace-match "From=20" nil t)
		  (if (looking-at "-")
		      (replace-match "=2D" nil t))))
	      (end-of-line)
	      ;; Fold long lines.
	      (while (> (current-column) 76) ; tab-width must be 1.
		(beginning-of-line)
		(forward-char 75)	; 75 chars plus an "="
		(search-backward "=" (- (point) 2) t)
		(insert "=\n")
		(end-of-line))
	      (forward-line))))))))

(defun quoted-printable-encode-string (string)
  "Encode the STRING as quoted-printable and return the result."
  (with-temp-buffer
    (if (multibyte-string-p string)
	(set-buffer-multibyte 'to)
      (set-buffer-multibyte nil))
    (insert string)
    (quoted-printable-encode-region (point-min) (point-max))
    (buffer-string)))

(provide 'qp)

;;; qp.el ends here
