;;; gnus-int.el --- backend interface functions for Gnus  -*- lexical-binding: t; -*-

;; Copyright (C) 1996-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: news

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

(require 'gnus)
(require 'message)
(require 'gnus-range)

(autoload 'gnus-run-hook-with-args "gnus-util")
(autoload 'gnus-agent-expire "gnus-agent")
(autoload 'gnus-agent-regenerate-group "gnus-agent")
(autoload 'gnus-agent-read-servers-validate-native "gnus-agent")
(autoload 'gnus-agent-possibly-synchronize-flags-server "gnus-agent")

(defcustom gnus-open-server-hook nil
  "Hook called just before opening connection to the news server."
  :group 'gnus-start
  :type 'hook)

(defcustom gnus-after-set-mark-hook nil
  "Hook called just after marks are set in a group."
  :version "24.1"
  :group 'gnus-start
  :type 'hook)

(defcustom gnus-before-update-mark-hook nil
  "Hook called just before marks are updated in a group."
  :version "24.1"
  :group 'gnus-start
  :type 'hook)

(defcustom gnus-server-unopen-status nil
  "The default status if the server is not able to open.
If the server is covered by Gnus agent, the possible values are
`denied', set the server denied; `offline', set the server offline;
nil, ask user.  If the server is not covered by Gnus agent, set the
server denied."
  :version "22.1"
  :group 'gnus-start
  :type '(choice (const :tag "Ask" nil)
		 (const :tag "Deny server" denied)
		 (const :tag "Unplug Agent" offline)))

;; Note: When this option is finally removed, also remove the entire
;; `gnus-start-news-server' function.
(defcustom gnus-nntp-server nil
  "The name of the host running the NNTP server."
  :group 'gnus-server
  :type '(choice (const :tag "disable" nil)
		 string))
(make-obsolete-variable 'gnus-nntp-server 'gnus-select-method "24.1")

(defvar gnus-internal-registry-spool-current-method nil
  "The current method, for the registry.")


(defun gnus-server-opened (command-method)
  "Check whether a connection to COMMAND-METHOD has been opened."
  (unless (eq (gnus-server-status command-method)
	      'denied)
    (let ((gnus-command-method
           (if (stringp command-method)
               (gnus-server-to-method command-method)
             command-method)))
      (funcall (inline (gnus-get-function gnus-command-method 'server-opened))
               (nth 1 gnus-command-method)))))

(defun gnus-status-message (command-method)
  "Return the status message from COMMAND-METHOD.
If COMMAND-METHOD is a string, it is interpreted as a group name.
The method this group uses will be queried."
  (let ((gnus-command-method
	 (if (stringp command-method)
	     (gnus-find-method-for-group command-method)
	   command-method)))
    (funcall (gnus-get-function gnus-command-method 'status-message)
	     (nth 1 gnus-command-method))))

;;;
;;; Server Communication
;;;

(defun gnus-start-news-server (&optional confirm)
  "Open a method for getting news.
If CONFIRM is non-nil, the user will be asked for an NNTP server."
  (let (how)
    (if gnus-current-select-method
	;; Stream is already opened.
	nil
      ;; Open NNTP server.
      (when confirm
	;; Read server name with completion.
	(setq gnus-nntp-server
	      (gnus-completing-read "NNTP server"
                                    nil nil gnus-nntp-server)))

      (when (and gnus-nntp-server
		 (stringp gnus-nntp-server)
		 (not (string= gnus-nntp-server "")))
	(setq gnus-select-method
	      (cond ((or (string= gnus-nntp-server "")
			 (string= gnus-nntp-server "::"))
		     (list 'nnspool (system-name)))
		    ((string-match "^:" gnus-nntp-server)
		     (list 'nnmh gnus-nntp-server
			   (list 'nnmh-directory
				 (file-name-as-directory
				  (expand-file-name
				   (substring gnus-nntp-server 1) "~/")))
			   (list 'nnmh-get-new-mail nil)))
		    (t
		     (list 'nntp gnus-nntp-server)))))

      (setq how (car gnus-select-method))
      (cond
       ((eq how 'nnspool)
	(require 'nnspool)
	(gnus-message 5 "Looking up local news spool..."))
       ((eq how 'nnmh)
	(require 'nnmh)
	(gnus-message 5 "Looking up mh spool..."))
       (t
	(require 'nntp)))
      (setq gnus-current-select-method gnus-select-method)
      (gnus-run-hooks 'gnus-open-server-hook)

      ;; Partially validate agent covered methods now that the
      ;; gnus-select-method is known.

      (if gnus-agent
          ;; NOTE: This is here for one purpose only.  By validating
          ;; the current select method, it converts the old 5.10.3,
          ;; and earlier, format to the current format.  That enables
          ;; the agent code within gnus-open-server to function
          ;; correctly.
          (gnus-agent-read-servers-validate-native gnus-select-method))

      (or
       ;; gnus-open-server-hook might have opened it
       (gnus-server-opened gnus-select-method)
       (gnus-open-server gnus-select-method)
       gnus-batch-mode
       (gnus-y-or-n-p
	(format-message
	 "%s (%s) open error: `%s'.  Continue? "
	 (car gnus-select-method) (cadr gnus-select-method)
	 (gnus-status-message gnus-select-method)))
       (gnus-error 1 "Couldn't open server on %s"
		   (nth 1 gnus-select-method))))))

(defun gnus-check-group (group)
  "Try to make sure that the server where GROUP exists is alive."
  (let ((method (gnus-find-method-for-group group)))
    (or (gnus-server-opened method)
	(gnus-open-server method))))

(defun gnus-check-server (&optional method silent)
  "Check whether the connection to METHOD is down.
If METHOD is nil, use `gnus-select-method'.
If it is down, start it up (again)."
  (let ((method (or method gnus-select-method))
	result)
    ;; Transform virtual server names into select methods.
    (when (stringp method)
      (setq method (gnus-server-to-method method)))
    (if (gnus-server-opened method)
	;; The stream is already opened.
	t
      ;; Open the server.
      (unless silent
	(gnus-message 5 "Opening %s server%s..." (car method)
		      (if (equal (nth 1 method) "") ""
			(format " on %s" (nth 1 method)))))
      (gnus-run-hooks 'gnus-open-server-hook)
      (prog1
	  (setq result (gnus-open-server method))
	(unless silent
	  (gnus-message
	   (if result 5 3)
	   "Opening %s server%s...%s" (car method)
	   (if (equal (nth 1 method) "") ""
	     (format " on %s" (nth 1 method)))
	   (if result
	       "done"
	     (format "failed: %s"
		     (nnheader-get-report-string (car method))))))))))

(defun gnus-get-function (method function &optional noerror)
  "Return a function symbol based on METHOD and FUNCTION."
  ;; Translate server names into methods.
  (unless method
    (error "Attempted use of a nil select method"))
  (when (stringp method)
    (setq method (gnus-server-to-method method)))
  ;; Check cache of constructed names.
  (let* ((method-sym (if gnus-agent
			 (inline (gnus-agent-get-function method))
		       (car method)))
	 (method-fns (get method-sym 'gnus-method-functions))
	 (func (let ((method-fnlist-elt (assq function method-fns)))
		 (unless method-fnlist-elt
		   (setq method-fnlist-elt
			 (cons function
			       (intern (format "%s-%s" method-sym function))))
		   (put method-sym 'gnus-method-functions
			(cons method-fnlist-elt method-fns)))
		 (cdr method-fnlist-elt))))
    ;; Maybe complain if there is no function.
    (unless (fboundp func)
      (unless (car method)
	(error "Trying to require a method that doesn't exist"))
      (require (car method))
      (when (not (fboundp func))
	(if noerror
	    (setq func nil)
	  (error "No such function: %s" func))))
    func))


;;;
;;; Interface functions to the backends.
;;;

(defun gnus-method-denied-p (method)
  (eq (nth 1 (assoc method gnus-opened-servers))
      'denied))

(defvar gnus-backend-trace nil)
(defvar gnus-backend-trace-elapsed nil)

(defun gnus-backend-trace (type form)
  (when gnus-backend-trace
    (with-current-buffer (gnus-get-buffer-create "*gnus trace*")
      (buffer-disable-undo)
      (goto-char (point-max))
      (insert (format-time-string "%H:%M:%S")
	      (format " %.2fs %s %S\n"
		      (if (numberp gnus-backend-trace-elapsed)
			  (float-time
			   (time-since gnus-backend-trace-elapsed))
			0)
		      type form))
      (setq gnus-backend-trace-elapsed (float-time)))))

(defun gnus-open-server (command-method)
  "Open a connection to COMMAND-METHOD."
  (gnus-backend-trace :opening gnus-command-method)
  (let* ((gnus-command-method (if (stringp command-method)
                                  (gnus-server-to-method command-method)
                                command-method))
         (elem (assoc gnus-command-method gnus-opened-servers))
         (server (gnus-method-to-server-name gnus-command-method)))
    ;; If this method was previously denied, we just return nil.
    (if (eq (nth 1 elem) 'denied)
	(progn
	  (gnus-message
	   1 "Server %s previously determined to be down; not retrying" server)
	  nil)
      ;; Open the server.
      (let* ((open-server-function
	      (gnus-get-function gnus-command-method 'open-server))
             (result
	      (condition-case err
		  (funcall open-server-function
			   (nth 1 gnus-command-method)
			   (nthcdr 2 gnus-command-method))
		(error
		 (gnus-message 1 "Unable to open server %s due to: %s"
			       server (error-message-string err))
		 nil)
		(quit
		 (if debug-on-quit
		     (debug "Quit")
		   (gnus-message 1 "Quit trying to open server %s" server))
		 nil)))
	     open-offline)
	;; If this hasn't been opened before, we add it to the list.
	(unless elem
	  (setq elem (list gnus-command-method nil)
		gnus-opened-servers (cons elem gnus-opened-servers)))
	;; Set the status of this server.
        (setcar
	 (cdr elem)
	 (cond (result
		(if (eq open-server-function 'nnagent-open-server)
		    ;; The agent's backend has a "special" status
		    'offline
		  'ok))
	       ((and gnus-agent
		     (gnus-agent-method-p gnus-command-method))
		(cond
		 (gnus-server-unopen-status
		  ;; Set the server's status to the unopen
		  ;; status.  If that status is offline,
		  ;; recurse to open the agent's backend.
		  (setq open-offline (eq gnus-server-unopen-status 'offline))
		  gnus-server-unopen-status)
		 ((not gnus-batch-mode)
		  (setq open-offline t)
		  'offline)
		 (t
		  ;; This agentized server was still denied
		  'denied)))
	       (t
		;; This unagentized server must be denied
		'denied)))

        ;; NOTE: I MUST set the server's status to offline before this
        ;; recursive call as this status will drive the
        ;; gnus-get-function (called above) to return the agent's
        ;; backend.
        (if open-offline
            ;; Recursively open this offline server to perform the
            ;; open-server function of the agent's backend.
            (let ((gnus-server-unopen-status 'denied))
              ;; Bind gnus-server-unopen-status to avoid recursively
              ;; prompting with "go offline?".  This is only a concern
              ;; when the agent's backend fails to open the server.
              (gnus-open-server gnus-command-method))
	  (when (and (eq (cadr elem) 'ok) gnus-agent
		     (gnus-agent-method-p gnus-command-method))
	    (save-excursion
	      (gnus-agent-possibly-synchronize-flags-server
	       gnus-command-method)))
	  (gnus-backend-trace :opened gnus-command-method)
          result)))))

(defun gnus-close-server (command-method)
  "Close the connection to COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (prog1
	(funcall (gnus-get-function gnus-command-method 'close-server)
	         (nth 1 gnus-command-method)
	         (nthcdr 2 gnus-command-method))
      (when-let* ((elem (assoc gnus-command-method gnus-opened-servers)))
        (setf (nth 1 elem) 'closed)))))

(defun gnus-request-list (command-method)
  "Request the active file from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-list)
             (nth 1 gnus-command-method))))

(defun gnus-server-get-active (server &optional ignored)
  "Return the active list for SERVER.
Groups matching the IGNORED regexp are excluded."
  (let ((method (gnus-server-to-method server))
	groups)
    (gnus-request-list method)
    (with-current-buffer nntp-server-buffer
      (let ((cur (current-buffer)))
	(goto-char (point-min))
	(unless (or (null ignored)
		    (string= ignored ""))
	  (delete-matching-lines ignored))
	(if (eq (car method) 'nntp)
	    (while (not (eobp))
	      (ignore-errors
		(push (gnus-group-full-name
		       (buffer-substring
			(point)
			(progn
			  (skip-chars-forward "^ \t")
			  (point)))
		       method)
		      groups))
	      (forward-line))
	  (while (not (eobp))
	    (ignore-errors
	      (push (if (eq (char-after) ?\")
			(gnus-group-full-name (read cur) method)
		      (let ((p (point)) (name ""))
			(skip-chars-forward "^ \t\\\\")
			(setq name (buffer-substring p (point)))
			(while (eq (char-after) ?\\)
			  (setq p (1+ (point)))
			  (forward-char 2)
			  (skip-chars-forward "^ \t\\\\")
			  (setq name (concat name (buffer-substring
						   p (point)))))
			(gnus-group-full-name name method)))
		    groups))
	    (forward-line)))))
    groups))

(defun gnus-finish-retrieve-group-infos (command-method infos data)
  "Read and update infos from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
  (gnus-backend-trace :finishing gnus-command-method)
  (prog1
      (funcall (gnus-get-function gnus-command-method
				  'finish-retrieve-group-infos)
	       (nth 1 gnus-command-method)
	       infos data)
      (gnus-backend-trace :finished gnus-command-method))))

(defun gnus-retrieve-group-data-early (command-method infos)
  "Start early async retrieval of data from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'retrieve-group-data-early)
             (nth 1 gnus-command-method)
             infos)))

(defun gnus-request-list-newsgroups (command-method)
  "Request the newsgroups file from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-list-newsgroups)
             (nth 1 gnus-command-method))))

(defun gnus-request-newgroups (date command-method)
  "Request all new groups since DATE from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (let ((func (gnus-get-function gnus-command-method 'request-newgroups t)))
      (when func
        (funcall func date (nth 1 gnus-command-method))))))

(defun gnus-request-regenerate (command-method)
  "Request a data generation from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-regenerate)
             (nth 1 gnus-command-method))))

(defun gnus-request-compact-group (group)
  (let* ((method (gnus-find-method-for-group group))
	 (gnus-command-method method)
	 (result
	  (funcall (gnus-get-function gnus-command-method
				      'request-compact-group)
		   (gnus-group-real-name group)
		   (nth 1 gnus-command-method) t)))
    result))

(defun gnus-request-compact (command-method)
  "Request groups compaction from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-compact)
             (nth 1 gnus-command-method))))

(defun gnus-request-group (group &optional dont-check command-method info)
  "Request GROUP.  If DONT-CHECK, no information is required."
  (let ((gnus-command-method
	 (or command-method (inline (gnus-find-method-for-group group)))))
    (when (stringp gnus-command-method)
      (setq gnus-command-method
	    (inline (gnus-server-to-method gnus-command-method))))
    (funcall (inline (gnus-get-function gnus-command-method 'request-group))
	     (gnus-group-real-name group) (nth 1 gnus-command-method)
	     dont-check
	     info)))

(defun gnus-request-group-description (group)
  "Request a description of GROUP."
  (let ((gnus-command-method (gnus-find-method-for-group group))
	(func 'request-group-description))
    (when (gnus-check-backend-function func group)
      (funcall (gnus-get-function gnus-command-method func)
	       (gnus-group-real-name group) (nth 1 gnus-command-method)))))

(defun gnus-request-group-scan (group info)
  "Request that GROUP get a complete rescan."
  (let ((gnus-command-method (gnus-find-method-for-group group))
	(func 'request-group-scan))
    (when (gnus-check-backend-function func group)
      (funcall (gnus-get-function gnus-command-method func)
	       (gnus-group-real-name group) (nth 1 gnus-command-method) info))))

(defun gnus-close-group (group)
  "Request the GROUP be closed."
  (let ((gnus-command-method (inline (gnus-find-method-for-group group))))
    (funcall (gnus-get-function gnus-command-method 'close-group)
	     (gnus-group-real-name group) (nth 1 gnus-command-method))))

(defun gnus-retrieve-headers (articles group &optional fetch-old)
  "Request headers for ARTICLES in GROUP.
If FETCH-OLD, retrieve all headers (or some subset thereof) in the group."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (cond
     ((and gnus-use-cache (numberp (car articles)))
      (gnus-cache-retrieve-headers articles group fetch-old))
     ((and gnus-agent (gnus-online gnus-command-method)
	   (gnus-agent-method-p gnus-command-method))
      (gnus-agent-retrieve-headers articles group fetch-old))
     (t
      (funcall (gnus-get-function gnus-command-method 'retrieve-headers)
	       articles (gnus-group-real-name group)
	       (nth 1 gnus-command-method) fetch-old)))))

(defun gnus-retrieve-articles (articles group)
  "Request ARTICLES in GROUP."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (funcall (gnus-get-function gnus-command-method 'retrieve-articles)
	     articles (gnus-group-real-name group)
	     (nth 1 gnus-command-method))))

(defun gnus-retrieve-groups (groups command-method)
  "Request active information on GROUPS from COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'retrieve-groups)
             groups (nth 1 gnus-command-method))))

(defun gnus-request-type (group &optional article)
  "Return the type (`post' or `mail') of GROUP (and ARTICLE)."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (if (not (gnus-check-backend-function
	      'request-type (car gnus-command-method)))
	'unknown
      (funcall (gnus-get-function gnus-command-method 'request-type)
	       (gnus-group-real-name group) article))))

(defun gnus-request-update-group-status (group status)
  "Change the status of a group.
Valid statuses include `subscribe' and `unsubscribe'."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (if (not (gnus-check-backend-function
	      'request-update-group-status (car gnus-command-method)))
	nil
      (funcall
       (gnus-get-function gnus-command-method 'request-update-group-status)
       (gnus-group-real-name group) status
       (nth 1 gnus-command-method)))))

(defun gnus-request-set-mark (group action)
  "Set marks on articles in the back end."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (if (not (gnus-check-backend-function
	      'request-set-mark (car gnus-command-method)))
	action
      (funcall (gnus-get-function gnus-command-method 'request-set-mark)
	       (gnus-group-real-name group) action
	       (nth 1 gnus-command-method))
      (gnus-run-hook-with-args gnus-after-set-mark-hook group action))))

(defun gnus-request-update-mark (group article mark)
  "Allow the back end to change the mark the user tries to put on an article."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (if (not (gnus-check-backend-function
	      'request-update-mark (car gnus-command-method)))
	mark
      (gnus-run-hook-with-args gnus-before-update-mark-hook group article mark)
      (funcall (gnus-get-function gnus-command-method 'request-update-mark)
	       (gnus-group-real-name group) article mark))))

(defun gnus-request-article (article group &optional buffer)
  "Request the ARTICLE in GROUP.
ARTICLE can either be an article number or an article Message-ID.
If BUFFER, insert the article in that group."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (funcall (gnus-get-function gnus-command-method 'request-article)
	     article (gnus-group-real-name group)
	     (nth 1 gnus-command-method) buffer)))

(defun gnus-request-thread (header group)
  "Request the headers in the thread containing the article specified by HEADER."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (funcall (gnus-get-function gnus-command-method 'request-thread)
	     header
	     (gnus-group-real-name group))))

(defun gnus-select-group-with-message-id (group message-id)
  "Activate and select GROUP with the given MESSAGE-ID selected.
Returns the article number of the message.

If GROUP is not already selected, the message will be the only one in
the group's summary."
  ;; TODO: is there a way to know at this point whether the group will
  ;; be newly-selected?  If so we could clean up the logic at the end
  ;;
  ;; save the new group's display parameter, if any, so we
  ;; can replace it temporarily with zero.
  (let ((saved-display
         (gnus-group-get-parameter group 'display :allow-list)))

    ;; Tell gnus we really don't want any articles
    (gnus-group-set-parameter group 'display 0)

    (unwind-protect
        (gnus-summary-read-group-1
         group (not :show-all) :no-article (not :kill-buffer)
         ;; The combination of no-display and this dummy list of
         ;; articles to select somehow makes it possible to open a
         ;; group with no articles in it.  Black magic.
         :no-display '(-1); select-articles
         )
      ;; Restore the new group's display parameter
      (gnus-group-set-parameter group 'display saved-display)))

  ;; The summary buffer was suppressed by :no-display above.
  ;; Create it now and insert the message
  (let ((group-is-new (gnus-summary-setup-buffer group)))
    (condition-case err
        (let ((article-number
               (gnus-summary-insert-subject message-id)))
          (unless article-number
            (signal 'error "message-id not in group"))
          (gnus-summary-select-article nil nil nil article-number)
          article-number)
      ;; Clean up the new summary and propagate the error
      (error (when group-is-new (gnus-summary-exit))
             (apply #'signal err)))))

(defun gnus-simplify-group-name (group)
  "Return the simplest representation of the name of GROUP.
This is the string that Gnus uses to identify the group."
  (gnus-group-prefixed-name
   (gnus-group-real-name group)
   (gnus-group-method group)))

(defun gnus-warp-to-article ()
  "Look up the current article in the group where it originated.
This command only makes sense for groups shows articles gathered
from other groups -- for instance, search results and the like."
  (interactive nil gnus-summary-mode)
  (let ((gnus-command-method
         (gnus-find-method-for-group gnus-newsgroup-name)))
    (or
     (when (gnus-check-backend-function
            'warp-to-article (car gnus-command-method))
       (funcall (gnus-get-function gnus-command-method 'warp-to-article)))
     (and (bound-and-true-p gnus-registry-enabled)
          (gnus-try-warping-via-registry)))))

(defun gnus-request-head (article group)
  "Request the head of ARTICLE in GROUP."
  (let* ((gnus-command-method (gnus-find-method-for-group group))
	 (head (gnus-get-function gnus-command-method 'request-head t))
	 res clean-up)
    (cond
     ;; Check the cache.
     ((and gnus-use-cache
	   (numberp article)
	   (gnus-cache-request-article article group))
      (setq res (cons group article)
	    clean-up t))
     ;; Check the agent cache.
     ((gnus-agent-request-article article group)
      (setq res (cons group article)
	    clean-up t))
     ;; Use `head' function.
     ((fboundp head)
      (setq res (funcall head article
                         (and (not gnus-override-method) (gnus-group-real-name group))
			 (nth 1 gnus-command-method))))
     ;; Use `article' function.
     (t
      (setq res (gnus-request-article article group)
	    clean-up t)))
    (when clean-up
      (with-current-buffer nntp-server-buffer
	(goto-char (point-min))
	(when (search-forward "\n\n" nil t)
	  (delete-region (1- (point)) (point-max)))
	(nnheader-fold-continuation-lines)))
    res))

(defun gnus-request-body (article group)
  "Request the body of ARTICLE in GROUP."
  (let* ((gnus-command-method (gnus-find-method-for-group group))
	 (head (gnus-get-function gnus-command-method 'request-body t))
	 res clean-up)
    (cond
     ;; Check the cache.
     ((and gnus-use-cache
	   (numberp article)
	   (gnus-cache-request-article article group))
      (setq res (cons group article)
	    clean-up t))
     ;; Check the agent cache.
     ((gnus-agent-request-article article group)
      (setq res (cons group article)
	    clean-up t))
     ;; Use `head' function.
     ((fboundp head)
      (setq res (funcall head article (gnus-group-real-name group)
			 (nth 1 gnus-command-method))))
     ;; Use `article' function.
     (t
      (setq res (gnus-request-article article group)
	    clean-up t)))
    (when clean-up
      (with-current-buffer nntp-server-buffer
	(goto-char (point-min))
	(when (search-forward "\n\n" nil t)
	  (delete-region (point-min) (1- (point))))))
    res))

(defun gnus-request-post (command-method)
  "Post the current buffer using COMMAND-METHOD."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-post)
             (nth 1 gnus-command-method))))

(defun gnus-request-expunge-group (group command-method)
  "Expunge GROUP, which is removing articles that have been marked as deleted."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (funcall (gnus-get-function gnus-command-method 'request-expunge-group)
             (gnus-group-real-name group)
             (nth 1 gnus-command-method))))

(defvar mail-source-plugged)
(defvar gnus-inhibit-demon)

(defun gnus-request-scan (group command-method)
  "Request a SCAN being performed in GROUP from COMMAND-METHOD.
If GROUP is nil, all groups on COMMAND-METHOD are scanned."
  (let ((gnus-command-method
	 (if group (gnus-find-method-for-group group) command-method))
	(gnus-inhibit-demon t)
	(mail-source-plugged gnus-plugged))
    (when (or gnus-plugged
	      (not (gnus-agent-method-p gnus-command-method)))
      (setq gnus-internal-registry-spool-current-method gnus-command-method)
      (funcall (gnus-get-function gnus-command-method 'request-scan)
	       (and group (gnus-group-real-name group))
	       (nth 1 gnus-command-method)))))

(defun gnus-request-update-info (info command-method)
  (when (gnus-check-backend-function
	 'request-update-info (car command-method))
    (let ((gnus-command-method
           (if (stringp command-method)
               (gnus-server-to-method command-method)
             command-method)))
      (funcall (gnus-get-function gnus-command-method 'request-update-info)
               (gnus-group-real-name (gnus-info-group info)) info
               (nth 1 gnus-command-method)))))

(defsubst gnus-request-marks (info command-method)
  "Request that COMMAND-METHOD update INFO."
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (when (gnus-check-backend-function
           'request-marks (car gnus-command-method))
      (let ((group (gnus-info-group info)))
        (and (funcall (gnus-get-function gnus-command-method 'request-marks)
                      (gnus-group-real-name group)
                      info (nth 1 gnus-command-method))
             ;; If the minimum article number is greater than 1, then all
             ;; smaller article numbers are known not to exist; we'll
             ;; artificially add those to the 'read range.
             (let* ((active (gnus-active group))
                    (min (car active)))
               (when (> min 1)
                 (let* ((range (if (= min 2) 1 (cons 1 (1- min))))
                        (read (gnus-info-read info))
                        (new-read (range-concat read (list range))))
                   (setf (gnus-info-read info) new-read)))
               info))))))

(defun gnus-request-expire-articles (articles group &optional force)
  (let* ((gnus-command-method (gnus-find-method-for-group group))
         ;; Filter out any negative article numbers; they can't be
         ;; expired here.
         (articles
          (delq nil (mapcar (lambda (n) (and (>= n 0) n)) articles)))
	 (gnus-inhibit-demon t)
	 (not-deleted
	  (funcall
	   (gnus-get-function gnus-command-method 'request-expire-articles)
	   articles (gnus-group-real-name group) (nth 1 gnus-command-method)
	   force)))
    (when (and gnus-agent
	       (gnus-agent-method-p gnus-command-method))
      (let ((expired-articles (gnus-sorted-difference articles not-deleted)))
        (when expired-articles
          (gnus-agent-expire expired-articles group 'force))))
    not-deleted))

(defun gnus-request-move-article (article group _server accept-function
					  &optional last move-is-internal)
  (let* ((gnus-command-method (gnus-find-method-for-group group))
	 (result (funcall (gnus-get-function gnus-command-method
					     'request-move-article)
			  article (gnus-group-real-name group)
			  (nth 1 gnus-command-method) accept-function
			  last move-is-internal)))
    (when (and result gnus-agent
	       (gnus-agent-method-p gnus-command-method))
      (gnus-agent-unfetch-articles group (list article)))
    result))

(defun gnus-request-accept-article (group &optional command-method last
					  no-encode)
  (let ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method)))
    (when (and (not gnus-command-method)
	       (stringp group))
      (setq gnus-command-method (or (gnus-find-method-for-group group)
                                    (gnus-group-name-to-method group))))
    (goto-char (point-max))
    ;; Make sure there's a newline at the end of the article.
    (unless (bolp)
      (insert "\n"))
    (unless no-encode
      (let ((message-options message-options))
        (message-options-set-recipient)
        (save-restriction
	  (message-narrow-to-head)
	  (mail-encode-encoded-word-buffer))
	(message-encode-message-body)))
    (let ((gnus-command-method (or gnus-command-method
				   (gnus-find-method-for-group group)))
	  (result
	   (funcall
	    (gnus-get-function gnus-command-method 'request-accept-article)
	    (if (stringp group) (gnus-group-real-name group) group)
	    (cadr gnus-command-method)
	    last)))
      (when (and gnus-agent
	         (gnus-agent-method-p gnus-command-method)
	         (cdr result))
	(gnus-agent-regenerate-group group (list (cdr result))))
      result)))

(defun gnus-request-replace-article (article group buffer &optional no-encode)
  (unless no-encode
    (let ((message-options message-options))
      (message-options-set-recipient)
      (save-restriction
	(message-narrow-to-head)
	(mail-encode-encoded-word-buffer))
      (message-encode-message-body)))
  (let* ((func (car (gnus-group-name-to-method group)))
         (result (funcall (intern (format "%s-request-replace-article" func))
			  article (gnus-group-real-name group) buffer)))
    (when (and gnus-agent (gnus-agent-method-p gnus-command-method))
      (gnus-agent-regenerate-group group (list article)))
    result))

(defun gnus-request-restore-buffer (article group)
  "Request a new buffer restored to the state of ARTICLE."
  (let ((gnus-command-method (gnus-find-method-for-group group)))
    (funcall (gnus-get-function gnus-command-method 'request-restore-buffer)
	     article (gnus-group-real-name group)
	     (nth 1 gnus-command-method))))

(defun gnus-request-create-group (group &optional command-method args)
  (let* ((gnus-command-method
          (or (if (stringp command-method)
                  (gnus-server-to-method command-method)
                command-method)
              (gnus-find-method-for-group group))))
    (funcall (gnus-get-function gnus-command-method 'request-create-group)
             (gnus-group-real-name group) (nth 1 gnus-command-method) args)))

(defun gnus-request-delete-group (group &optional force)
  (let* ((gnus-command-method (gnus-find-method-for-group group))
	 (result
	  (funcall (gnus-get-function gnus-command-method 'request-delete-group)
		   (gnus-group-real-name group) force (nth 1 gnus-command-method))))
    (when result
      (gnus-cache-delete-group group)
      (gnus-agent-delete-group group))
    result))

(defun gnus-request-rename-group (group new-name)
  (let* ((gnus-command-method (gnus-find-method-for-group group))
	 (result
	  (funcall (gnus-get-function gnus-command-method 'request-rename-group)
		   (gnus-group-real-name group)
		   (gnus-group-real-name new-name) (nth 1 gnus-command-method))))
    (when result
      (gnus-cache-rename-group group new-name)
      (gnus-agent-rename-group group new-name))
    result))

(defun gnus-close-backends ()
  ;; Send a close request to all backends that support such a request.
  (let ((methods gnus-valid-select-methods)
	(gnus-inhibit-demon t)
	func gnus-command-method)
    (while (setq gnus-command-method (pop methods))
      (when (fboundp (setq func (intern
				 (concat (car gnus-command-method)
					 "-request-close"))))
	(funcall func)))))

(defun gnus-asynchronous-p (command-method)
  (let ((func (gnus-get-function command-method 'asynchronous-p t)))
    (when (fboundp func)
      (let ((gnus-command-method command-method))
        (funcall func)))))

(defun gnus-remove-denial (command-method)
  (let* ((gnus-command-method
         (if (stringp command-method)
             (gnus-server-to-method command-method)
           command-method))
         (elem (assoc gnus-command-method gnus-opened-servers))
	 (status (cadr elem)))
    ;; If this hasn't been opened before, we add it to the list.
    (when (eq status 'denied)
      ;; Set the status of this server.
      (setcar (cdr elem) 'closed))))

(provide 'gnus-int)

;;; gnus-int.el ends here
