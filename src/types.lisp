;;;; types.lisp

(in-package #:coalton-impl)

;;; A type constructor is not a constructor for a value, but a
;;; constructor for a *type*! Get with the program!
(defstruct tycon
  "A constructor for type applications."
  (name (required 'name) :type symbol                 :read-only t)
  (arity 0               :type unsigned-byte          :read-only t)
  ;; A list of (CONSTRUCTOR-NAME . PREDICATE-NAME) pairs.
  ;;
  ;; The CONSTRUCTOR-NAME names a known function that constructs a
  ;; value of TYCON type. The PREDICATE-NAME also names a known
  ;; function that tests whether an object is this particular summand.
  ;;
  ;; This isn't read-only because we might set it later. It would be
  ;; nice to make it read-only though.
  (constructors nil      :type alexandria:proper-list))

;;; TODO: figure out type aliases.
(define-global-var **type-definitions** (make-hash-table :test 'eql)
  "Database of Coalton type definitions. These are mappings from symbols to type constructors.")

(defmacro define-type-constructor (name arity)
  `(setf (gethash ',name **type-definitions**)
         (make-tycon :name ',name :arity ',arity)))

(defun tycon-knownp (tycon-name)
  (check-type tycon-name symbol)
  (nth-value 1 (gethash tycon-name **type-definitions**)))

(defun find-tycon (tycon-name)
  (check-type tycon-name symbol)
  (or (gethash tycon-name **type-definitions**)
      (error "Couldn't find definition of tycon ~S" tycon-name)))

(defun (setf find-tycon) (new-value tycon-name)
  (check-type tycon-name symbol)
  (check-type new-value tycon)
  (when (tycon-knownp tycon-name)
    (warn "Clobbering tycon ~S" tycon-name))
  (setf (gethash tycon-name **type-definitions**) new-value))


;;; TY is forward declared in node.lisp

(defstruct (tyvar (:include ty)
                  (:constructor %make-tyvar))
  "A type variable."
  (id       0   :type integer          :read-only t)
  (instance nil :type (or null ty)     :read-only nil)
  (name     nil :type (or null symbol) :read-only nil))

(defstruct (tyapp (:include ty)
                  (:constructor tyapp (constructor &rest types)))
  "A type application. (Note that this could be the application of a 0-arity constructor.)"
  (constructor  nil :type tycon     :read-only t)
  (types        nil :type type-list :read-only t))

(defun tyapp-name (tyapp)
  (tycon-name (tyapp-constructor tyapp)))

;; We have a special constructor for functions because we handle
;; multi-argument functions without a separate tuple type.
(defstruct (tyfun (:include ty)
                  (:constructor tyfun (from to)))
  "A function type."
  (from nil :type type-list :read-only t)
  (to   nil :type ty        :read-only t))

(defun tyfun-arity (tyfun)
  (length (tyfun-from tyfun)))


#+sbcl (declaim (sb-ext:freeze-type ty tyvar tyapp tyfun))

(defvar *next-variable-id* 0)
(defun make-variable ()
  (prog1 (%make-tyvar :id *next-variable-id*)
    (incf *next-variable-id*)))

(defun variable-name (v)
  (or (tyvar-name v)
      (setf (tyvar-name v) (gensym "T"))))

(defun unparse-type (ty)
  (etypecase ty
    (tyvar
     (if (tyvar-instance ty)
         (unparse-type (tyvar-instance ty))
         (variable-name ty)))

    (tyapp
     (if (null (tyapp-types ty))
         (tyapp-name ty)
         (list* (tyapp-name ty) (mapcar #'unparse-type (tyapp-types ty)))))
    
    (tyfun
     (let ((from (mapcar #'unparse-type (tyfun-from ty)))
           (to (unparse-type (tyfun-to ty))))
       (cond
         ((endp from)        `(coalton:-> () ,to))
         ((endp (rest from)) `(coalton:-> ,(first from) ,to))
         (t                  `(coalton:-> ,from ,to)))))))

(defun prune (ty)
  (etypecase ty
    (tyvar
     (let ((instance (tyvar-instance ty)))
       (if (null instance)
           ty
           (setf (tyvar-instance ty) (prune instance)))))

    (tyapp
     ty)

    (tyfun
     ty)))

(defun occurs-in-type (v t2)
  (let ((pruned-t2 (prune t2)))
    ;; XXX is this RIGHT?
    (if (equalp v pruned-t2)
        t
        (typecase pruned-t2
          (tyapp (occurs-in v (tyapp-types pruned-t2)))
          (tyfun (occurs-in v (cons (tyfun-to pruned-t2) (tyfun-from pruned-t2))))
          (otherwise nil)))))

(defun occurs-in (ty types)
  (some (lambda (ty2) (occurs-in-type ty ty2)) types))

(defun is-generic (v non-generic)
  (not (occurs-in v non-generic)))

(defun fresh (ty &optional (non-generic nil))
  "Take a type, and substitute free variables with fresh ones."
  ;; XXX: Verify this hash table is correct.
  (let ((table (make-hash-table :test 'equalp)))
    (labels ((freshrec (tp)
               (let ((ptp (prune tp)))
                 (etypecase ptp
                   (tyvar
                    (if (not (is-generic ptp non-generic))
                        ptp
                        ;; XXX make correct
                        (multiple-value-bind (var exists?) (gethash ptp table)
                          (if exists?
                              var
                              (setf (gethash ptp table) (make-variable))))))
                   (tyapp
                    (apply #'tyapp
                           (tyapp-constructor ptp)
                           (mapcar #'freshrec (tyapp-types ptp))))
                   (tyfun
                    (tyfun (mapcar #'freshrec (tyfun-from ptp))
                           (freshrec (tyfun-to ptp))))))))
      (values (freshrec ty) (alexandria:hash-table-alist table)))))

(defun assoc-find (env name)
  (let ((entry (assoc name env)))
    (and entry
         (cdr entry))))

(defun unify (ty1 ty2)
  (let ((pty1 (prune ty1))
        (pty2 (prune ty2)))
    (cond
      ((tyvar-p pty1)
       (unless (equalp pty1 pty2)
         (when (occurs-in-type pty1 pty2)
           (error-typing "Attempting to infinitely recurse into unification."))
         (setf (tyvar-instance pty1) pty2)))
      ((tyvar-p pty2)
       (unify pty2 pty1))
      ((and (tyfun-p pty1)
            (tyfun-p pty2))
       (let ((arity-1 (length (tyfun-from pty1)))
             (arity-2 (length (tyfun-from pty2))))
         (unless (= arity-1 arity-2)
           (error-typing "Type mismatch (mismatched arities of ~D and ~D)" arity-1 arity-2))
         (mapc #'unify (tyfun-from pty1) (tyfun-from pty2))
         (unify (tyfun-to pty1) (tyfun-to pty2))))
      ((and (tyapp-p pty1)
            (tyapp-p pty2))
       (let ((name1 (tyapp-name pty1)) (types1 (tyapp-types pty1))
             (name2 (tyapp-name pty2)) (types2 (tyapp-types pty2)))
         (when (or (not (eq name1 name2))
                   (not (= (length types1) (length types2))))
             (error-typing "Type mismatch: ~S and ~S"
                           (unparse-type pty1)
                           (unparse-type pty2)))
         (mapc #'unify types1 types2)))
      (t
       (error-typing "Type mismatch: ~S and ~S"
                     (unparse-type ty1)
                     (unparse-type ty2)))))
  nil)
