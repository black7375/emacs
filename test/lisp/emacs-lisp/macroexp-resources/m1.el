;;; m1.el --- Some sample code for macroexp-tests    -*- lexical-binding: t; -*-

;; Copyright (C) 2021-2025 Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Keywords:

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

;;; Code:

(defconst macroexp--m1-tests-filename (macroexp-file-name))

(eval-when-compile
  (defconst macroexp--m1-tests-comp-filename (macroexp-file-name)))

(defun macroexp--m1-tests-file-name ()
  (macroexp--test-get-file-name))

(provide 'm1)
;;; m1.el ends here
