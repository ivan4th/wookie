;; wookie-plugin-export provides a shared namespace for plugins to provide
;; their public symbols to. apps can :use this package to gain access to
;; the shared plugin namespace.
(defpackage :wookie-plugin-export
  (:use :cl))

(in-package :wookie)

(defvar *plugin-folders* (list "./wookie-plugins/"
                               (asdf:system-relative-pathname :wookie #P"core-plugins/"))
  "A list of directories where Wookie plugins can be found.")

(defvar *available-plugins* nil
  "A plist (generated by load-plugins) that holds a mapping of plugin <--> ASDF
   systems for the plugins. Reset on each load-plugins run.")

(defun register-plugin (plugin-name init-function unload-function)
  "Register a plugin in the Wookie plugin system. Generally this is called from
   a plugin.lisp file, but can also be called elsewhere in the plugin. The
   plugin-name argument must be a unique keyword, and init-fn is the
   initialization function called that loads the plugin (called only once, on
   register)."
  (vom:debug1 "(plugin) Register plugin ~s" plugin-name)
  (let ((plugin-entry (list :name plugin-name
                            :init-function init-function
                            :unload-function unload-function)))
    ;; if enabled (And not already loaded), load it
    (when (and (find plugin-name *enabled-plugins*)
               (not (gethash plugin-name (wookie-state-plugins *state*))))
      (setf (gethash plugin-name (wookie-state-plugins *state*)) plugin-entry)
      (funcall init-function))))

(defun unload-plugin (plugin-name)
  "Unload a plugin from the wookie system. If it's currently registered, its
   unload-function will be called.
   
   Also unloads any current plugins that depend on this plugin. Does this
   recursively so all depencies are always resolved."
  (vom:debug1 "(plugin) Unload plugin ~s" plugin-name)
  ;; unload the plugin
  (let ((plugin (gethash plugin-name (wookie-state-plugins *state*))))
    (when plugin
      (funcall (getf plugin :unload-function (lambda ())))
      (remhash plugin-name (wookie-state-plugins *state*))))

  (let ((asdf (getf *available-plugins* plugin-name)))
    (when asdf
      (let* ((tmp-deps (asdf:component-depends-on
                            'asdf:load-op
                            (asdf:find-system asdf)))
             (plugin-deps (mapcar (lambda (asdf)
                                    (intern (asdf:component-name (asdf:find-system asdf)) :keyword))
                                  (cdadr tmp-deps)))
             (plugin-systems (loop for system in *available-plugins*
                                   for i from 0
                                   when (oddp i)
                                     collect (intern (string system) :keyword)))
             (to-unload (intersection plugin-deps plugin-systems)))
        (vom:debug1 "(plugin) Unload deps for ~s ~s" plugin-name to-unload)
        (dolist (asdf to-unload)
          (let ((plugin-name (getf-reverse *available-plugins* asdf)))
            (unload-plugin plugin-name)))))))

(defun plugin-config (plugin-name)
  "Return the configuration for a plugin. Setfable."
  (unless (hash-table-p (wookie-state-plugin-config *state*))
    (setf (wookie-state-plugin-config *state*) (make-hash-table :test #'eq)))
  (gethash plugin-name (wookie-state-plugin-config *state*)))

(defun (setf plugin-config) (config plugin-name)
  "Allow setting of plugin configuration via setf."
  (unless (hash-table-p (wookie-state-plugin-config *state*))
    (setf (wookie-state-plugin-config *state*) (make-hash-table :test #'eq)))
  (setf (gethash plugin-name (wookie-state-plugin-config *state*)) config))

(defun plugin-request-data (plugin-name request)
  "Retrieve the data stored into a request object for the plugin-name (keyword)
   plugin. This function is setfable."
  (let ((data (request-plugin-data request)))
    (when (hash-table-p data)
      (gethash plugin-name data))))

(defun (setf plugin-request-data) (data plugin-name request)
  "When a plugin wants to store data available to the main app, it can do so by
   storing the data into the request's plugin data. This function allows this by
   taking the plugin-name (keyword), request object passed into the route, and
   the data to store."
  (vom:debug1 "(plugin) Set plugin data ~s: ~a" plugin-name data)
  (unless (hash-table-p (request-plugin-data request))
    (setf (request-plugin-data request) (make-hash-table :test #'eq)))
  (setf (gethash plugin-name (request-plugin-data request)) data))

(defun resolve-dependencies (&key ignore-loading-errors (use-quicklisp t))
  "Load the ASDF plugins and resolve all of their dependencies. Kind of an
   unfortunate name. Will probably be renamed."
  ;; note that these are macros to fix some dependency issues when building
  ;; Wookie on some systems (that don't have quicklisp). TBH they could probably
  ;; be functions. oh well.
  (macrolet ((load-system (system &key use-quicklisp)
               ;; FUCK the system
               (if (and use-quicklisp (find-package :ql))
                   (list (intern "QUICKLOAD" :ql) system)
                   `(asdf:oos 'asdf:load-op ,system)))
             (load-system-with-handler (system &key use-quicklisp)
               `(handler-case
                  (load-system ,system :use-quicklisp ,use-quicklisp)
                  ((or ,(when (find-package :quicklisp-client)
                          (intern "SYSTEM-NOT-FOUND" :quicklisp-client))
                       asdf::missing-component) (e)
                    (vom:warn "(plugin) Failed to load dependency for ~s (~s)"
                              asdf-system
                              ,(when (find-package :quicklisp-client)
                                 (list (intern "SYSTEM-NOT-FOUND-NAME" :quicklisp-client) 'e)))))))
    ;; make asdf/quicklisp shutup when loading. we're logging all this junk
    ;; newayz so nobody wants to see that shit
    (let* ((*log-output* *standard-output*)
           (*standard-output* (make-broadcast-stream)))
      (if ignore-loading-errors
          ;; since we're ignoring errors, we need to individually load each plugin
          ;; so if there's an error we can keep loading the other plugins (and of
          ;; course generate a warning).
          (dolist (enabled *enabled-plugins*)
            (let ((asdf-system (getf *available-plugins* enabled)))
              (when asdf-system
                (vom:debug1 "(plugin) Loading plugin ASDF ~s and deps" asdf-system)
                (load-system-with-handler asdf-system :use-quicklisp use-quicklisp))))

          ;; create an asdf system that houses all the enabled plugins as deps, then
          ;; load it (a lot faster than individually loading each asdf system).
          (let ((asdf-list (loop for plugin in *enabled-plugins*
                                 collect (getf *available-plugins* plugin))))
            (apply (eval (cadr (macroexpand-1 '(asdf:defsystem test))))
                   'wookie-plugin-load-system
                   `(:author "The high king himself, Lord Wookie."
                     :license "Unconditional servitude."
                     :version "1.0.0"
                     :description "An auto-generated ASDF system that helps make loading plugins fast."
                     :depends-on ,asdf-list))
            (load-system :wookie-plugin-load-system :use-quicklisp use-quicklisp))))))

(defun match-plugin-asdf (plugin-name asdf-system)
  "Match a plugin and an ASDF system toeach other."
  (setf (getf *available-plugins* plugin-name) asdf-system))

(defparameter *current-plugin-name* nil
  "Used by load-plugins to tie ASDF systems to a :plugin-name")
  
(defparameter *scanner-plugin-name*
  (cl-ppcre:create-scanner "[/\\\\]([a-z-_]+)[/\\\\]?$" :case-insensitive-mode t)
  "Basically unix's basename in a regex.")

(defun load-plugins (&key ignore-loading-errors (use-quicklisp t))
  "Load all plugins under the *plugin-folder* fold (set with set-plugin-folder).
   There is also the option to compile the plugins (default nil)."
  (vom:debug "(plugin) Load plugins ~s" *plugin-folders*)
  (unless (wookie-state-plugins *state*)
    (setf (wookie-state-plugins *state*) (make-hash-table :test #'eq)))
  ;; unload current plugins
  (loop for name being the hash-keys of (wookie-state-plugins *state*) do
    (unload-plugin name))
  (setf *available-plugins* nil)
  (dolist (plugin-folder *plugin-folders*)
    (dolist (dir (cl-fad:list-directory plugin-folder))
      (let* ((dirstr (namestring dir))
             (plugin-name (aref (cadr (multiple-value-list (cl-ppcre:scan-to-strings *scanner-plugin-name* dirstr))) 0))
             (plugin-name (intern (string-upcase plugin-name) :keyword))
             (plugin-defined-p (getf *available-plugins* plugin-name)))
        ;; only load the plugin if a) there's not a plugin <--> ASDF match
        ;; already (meaning the plugin is defined) and b) the plugin dir exists
        (when (and (not plugin-defined-p)
                   (cl-fad:directory-exists-p dir))
          (let ((plugin-file (concatenate 'string dirstr "plugin.asd")))
            (if (cl-fad:file-exists-p plugin-file)
                (progn
                  (vom:debug1 "(plugin) Load ~a" plugin-file)
                  (let ((*current-plugin-name* plugin-name))
                    (load plugin-file)))
                (vom:warn "(plugin) Missing ~a" plugin-file)))))))
  (resolve-dependencies :ignore-loading-errors ignore-loading-errors :use-quicklisp use-quicklisp))

(defmacro defplugin (&rest asdf-defsystem-args)
  "Simple wrapper around asdf:defsystem that maps a plugin-name (hopefully in
   *current-plugin-name*) to the ASDF system the plugin defines."
  `(progn
     (asdf:defsystem ,@asdf-defsystem-args)
     (wookie::match-plugin-asdf wookie::*current-plugin-name*
                                ,(intern (string-upcase (string (car asdf-defsystem-args)))
                                         :keyword))))

(defmacro defplugfun (name args &body body)
  "Define a plugin function that is auto-exported to the :wookie-plugin-export
   package."
  `(progn
     (defun ,name ,args ,@body)
     (shadowing-import ',name :wookie-plugin-export)
     (export ',name :wookie-plugin-export)))


