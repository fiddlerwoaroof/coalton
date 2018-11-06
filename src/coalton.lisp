;;;; coalton.lisp

(in-package #:coalton-impl)

;;; # Compiler
;;;
;;; The compiler is a combination of a code analyzer and code
;;; generator. The main analysis to be done is type checking. The code
;;; generator just generates valid Common Lisp, to be further
;;; processed by the Common Lisp compiler. Generally, this code will
;;; be generated at macroexpansion time of the ambient Common Lisp
;;; compiler. See the COALTON macro.

(define-global-var **toplevel-operators** '(coalton:progn
                                            coalton:coalton))
(define-global-var **special-operators** `(,@**toplevel-operators**
                                           coalton:define
                                           coalton:define-type-alias
                                           coalton:define-type
                                           coalton:declare))

;;; ## Value Analysis
;;;
;;; For values, we follow the usual grammar for the simply typed
;;; lambda calculus, with a modicum of practical extensions. The
;;; precise grammar is:
;;;
;;;     <atom> := <CL Integer>
;;;             | ...
;;;
;;;     <expr> := <atom>
;;;             | <variable>         ; variable
;;;             | (<expr> <expr>)    ; application
;;;             | (fn <variable> <expression>)
;;;                                  ; abstraction
;;;             | (let ((<variable> <expression>) ...) <expression>)
;;;                                  ; lexical binding
;;;             | (if <expr> <expr> <expr>
;;;                                  ; conditional
;;;             | (progn <expr> ...) ; sequence
;;;             | (lisp <type> <expr>)
;;;                                  ; Lisp escape
;;;             | (letrec ((<variable> <expression>) ...) <expression>)
;;;
;;; TODO: Some syntax isn't accounted for:
;;;
;;;          - Top-level syntax
;;;          - All of the desired atomic data
;;;          - Variable declarations
;;;          - Literal syntax for some constructors
;;;

(defun compile-value-to-lisp (value)
  "Compile the node VALUE into Lisp."
  (check-type value node)
  (labels ((analyze (expr)
             (etypecase expr
               (node-literal
                (node-literal-value expr))

               (node-variable
                (node-variable-name expr))

               (node-abstraction
                (let ((vars (node-abstraction-vars expr)))
                  `(lambda  (,@vars)
                     (declare (ignorable ,@vars))
                     ,(analyze (node-abstraction-subexpr expr)))))

               (node-let
                `(let ,(loop :for (var . val) :in (node-let-bindings expr)
                             :collect `(,var ,(analyze val)))
                   ,(analyze (node-let-subexpr expr))))

               (node-letrec
                ;; TODO: fixme? this is broken... this isn't quite
                ;; right and only works well for functions
                (let* ((bindings (node-letrec-bindings expr))
                       (subexpr (node-letrec-subexpr expr))
                       (vars (mapcar #'car bindings))
                       (vals (mapcar #'cdr bindings)))
                  `(let (,@vars)
                     (psetf ,@(loop :for var :in vars
                                    :for val :in vals
                                    :collect var
                                    :collect (analyze val)))
                     ,(analyze subexpr))))

               (node-if
                `(if ,(analyze (node-if-test expr))
                     ,(analyze (node-if-then expr))
                     ,(analyze (node-if-else expr))))

               (node-lisp
                (node-lisp-form expr))

               (node-sequence
                `(progn
                   ,@(mapcar #'analyze (node-sequence-exprs expr))))

               (node-application
                (let ((rator (analyze (node-application-rator expr)))
                      (rands (mapcar #'analyze (node-application-rands expr))))
                  `(funcall ,rator ,@rands))))))
    (analyze value)))

;;; ## Compilation

(defun compile-toplevel-form (form)
  (cond
    ;; An atomic form at the top-level. Consider me spooked.
    ;;
    ;; TODO: Actually do something proper here.
    ((atom form)
     (error "Atomic form ~S found at the top-level." form))

    ((member (first form) **special-operators**)
     (compile-toplevel-special-form (first form) form))

    (t
     (error "I don't know how to deal with non-special forms."))))

(defgeneric compile-toplevel-special-form (operator whole))

(defmethod compile-toplevel-special-form ((operator (eql 'coalton:progn)) whole)
  (error "PROGN should be elminiated at the top-level."))

(defmethod compile-toplevel-special-form ((operator (eql 'coalton:coalton)) whole)
  (error "COALTON should be eliminated at the top-level."))

(defun check-compound-form (form starts-with)
  "Check that FORM is a compound form starting with STARTS-WITH."
  (unless (and (not (atom form))
               (eql starts-with (first form)))
    (error-parsing form "The form is expected to be compound starting with ~S" starts-with)))

(defun check-compound-form-length (form from &optional (to from))
  "Check that FORM is of length between FROM and TO inclusive. If TO is NIL (default: FROM), then the length can be unbounded."
  (check-type from integer)
  (check-type to (or null integer))
  (unless (if (null to)
              (<= from (length form))
              (<= from (length form) to))
    (error-parsing form "The form is expected to have length between ~D and ~
                         ~:[infinity~;~:*~D~] inclusive."
                   from
                   to)))

(defun parse-declare-form (form)
  "Parse a COALTON:DECLARE form."
  (check-compound-form form 'coalton:declare)
  (check-compound-form-length form 3)
  (destructuring-bind (declare-symbol var type-expr) form
    (declare (ignore declare-symbol))
    (unless (symbolp var)
      (error-parsing form "The second argument should be a symbol."))
    (values var (parse-type-expression type-expr))))

(defmethod compile-toplevel-special-form ((operator (eql 'coalton:declare)) whole)
  (multiple-value-bind (var type) (parse-declare-form whole)
    ;; This just has compile-time effects. It doesn't produce
    ;; executable code.
    (unless (var-knownp var)
      (forward-declare-variable var))
    (setf (var-declared-type var) type)
    ;; Produce no code.
    (values)))

#+#:ignore
(defun parse-define-type-alias-form (form)
  "Parse a COALTON:DEFINE-TYPE-ALIAS form."
  (check-compound-form form 'coalton:define-type-alias)
  (check-compound-form-length form 3)
  (destructuring-bind (def-symbol tyname type-expr) form
    (declare (ignore def-symbol))
    (unless (symbolp tyname)
      (error-parsing form "The second argument should be a symbol."))
    (values tyname (parse-type-expression type-expr))))

#+#:ignore
(defmethod compile-toplevel-special-form ((operator (eql 'coalton:define-type-alias)) whole)
  (multiple-value-bind (tyname type) (parse-define-type-alias-form whole)
    ;; Establish the alias as a side-effect.
    ;;
    ;; TODO: Make this better. Actually check things, and abstract out
    ;; the whole table access dealio here.
    (setf (gethash tyname **type-definitions**) `(alias ,type))
    ;; Produce no code.
    (values)))

(defun parse-define-type-form (form)
  (destructuring-bind (def-type type &rest ctors) form
    (assert (eql 'coalton:define-type def-type))
    (assert (not (null type)))
    (setf type (alexandria:ensure-list type))
    (destructuring-bind (tycon-name &rest tyvar-names) type
      (when (tycon-knownp tycon-name)
        (cerror "Clobber the tycon." "Already defined tycon: ~S" tycon-name))
      (assert (every #'symbolp tyvar-names))
      (let* ((arity (length tyvar-names))
             (tycon (make-tycon :name tycon-name :arity arity))
             (constructors nil))
        (multiple-value-bind (ty fvs) (parse-type-expression type :extra-tycons (list tycon))
          (dolist (ctor ctors)
            (typecase ctor
              (symbol
               (push (list ':variable ctor ty) constructors))
              (alexandria:proper-list
               (destructuring-bind (name &rest argtys) ctor
                 (push (list ':function
                             name
                             (make-function-type
                              (loop :for argty :in argtys
                                    :collect (parse-type-expression
                                              argty
                                              :extra-tycons (list tycon)
                                              :variable-assignments fvs))
                              ty))
                       constructors)))))
          (values tycon ty constructors))))))

(defmethod compile-toplevel-special-form ((operator (eql 'coalton:define-type)) whole)
  (multiple-value-bind (tycon generic-ty ctors) (parse-define-type-form whole)
    (let* ((tycon-name (tycon-name tycon))
           (ctor-names (mapcar #'second ctors))
           (pred-names (loop :for ctor-name :in ctor-names
                             :collect (alexandria:format-symbol nil "~A-P" ctor-name))))
      ;; Record the ctors and predicates.
      (setf (tycon-constructors tycon) (mapcar #'cons ctor-names pred-names))

      ;; Make the tycon known. We clobber it if it exists.
      (setf (find-tycon tycon-name) tycon)

      ;; Declare the types of the new things.
      (loop :for (_ name ty) :in ctors
            :do (unless (var-knownp name)
                  (forward-declare-variable name))
                (setf (var-declared-type name) ty))

      ;; Declare the predicates
      (loop :with pred-ty := (make-function-type generic-ty boolean-type)
            :for (_ . pred-name) :in (tycon-constructors tycon)
            :do (unless (var-knownp pred-name)
                  (forward-declare-variable pred-name))
                (setf (var-declared-type pred-name) pred-ty))
      ;; Compile into sensible Lisp.
      ;;
      ;; TODO: Structs? Vectors? Classes? This should be thought
      ;; about. Let's start with classes.
      `(progn
         ;; Define types. Create the superclass.
         ;;
         ;; TODO: handle special case of 1 ctor.
         ,(if (endp ctors)
              `(deftype ,tycon-name () nil)
              `(defclass ,tycon-name ()
                 ()
                 (:metaclass abstract-class)))

         ;; Create all of the subclasses.
         ,@(loop :for (kind name _) :in ctors
                 :collect (ecase kind
                            (:variable
                             `(defclass ,name (,tycon-name)
                                ()
                                (:metaclass singleton-class)))
                            (:function
                             `(defclass ,name (,tycon-name)
                                ;; XXX: For now, we just store a vector.
                                ((value :initarg :value
                                        :type simple-vector))
                                (:metaclass final-class))))
              :collect (ecase kind
                         (:variable
                          `(defmethod print-object ((self ,name) stream)
                             (format stream "#.~s" ',name)))
                         (:function
                          `(defmethod print-object ((self ,name) stream)
                             (format stream "#.(~s~{ ~s~})"
                                     ',name
                                     (coerce (slot-value self 'value) 'list))))))

         ;; Define constructors
         ,@(loop :for (kind name ty) :in ctors
                 :append (ecase kind
                           ;; TODO: Should we emulate a global
                           ;; lexical? The type inference assumes as
                           ;; much.
                           (:variable
                            (list
                             `(define-global-var* ,name (make-instance ',name))))
                            (:function
                             (let* ((arity (tyfun-arity ty))
                                    (args (loop :repeat arity
                                                :collect (gensym "A"))))
                               (list
                                `(defun ,name ,args
                                   (make-instance ',name :value (vector ,@args)))
                                `(define-global-var* ,name #',name))))))
         ;; Define predicates
         ,@(loop :for (ctor-name . pred-name) :in (tycon-constructors tycon)
                 :collect `(defun ,pred-name (object)
                             (typep object ',ctor-name)))
         ',tycon-name))))

(defun parse-define-form (form)
  "Parse a COALTON:DEFINE form."
  (check-compound-form form 'coalton:define)
  (check-compound-form-length form 3)
  ;; Defines either define a value or a function. Values and functions
  ;; in Coalton occupy the namespace, but the intent of the user can
  ;; be distinguished. A definition either looks like:
  ;;
  ;;     (DEFINE <var> <val>)
  ;;
  ;; or
  ;;
  ;;     (DEFINE (<fvar> <arg>*) <val>)
  ;;
  ;; The former defines a variable, the latter defines a function.
  (destructuring-bind (def-symbol var-thing val) form
    (declare (ignore def-symbol))
    (cond
      ((null var-thing)
       (error-parsing form "Found a null value where a symbol or function ~
                            was expected."))
      ((symbolp var-thing)
       (parse-define-form-variable var-thing val))
      ((and (listp var-thing)
            (every #'symbolp var-thing))
       (parse-define-form-function (first var-thing) (rest var-thing) val))
      (t
       (error-parsing form "Invalid second argument.")))))

(defun parse-define-form-variable (var val)
  ;; The (DEFINE <var> <val>) case.
  (check-type var symbol)
  ;; XXX: Should this be LETREC too? Probably for something like F = x => ... F.
  (values var (parse-form val)))

(defun parse-define-form-function (fvar args val)
  (check-type fvar symbol)
  ;; The (DEFINE (<fvar> . <args>) <val>) case.
  (values fvar (parse-form
                `(coalton:letrec ((,fvar (coalton:fn ,args ,val)))
                                 ,fvar))))

;;; TODO: make sure we can lexically shadow global bindings
(defmethod compile-toplevel-special-form ((operator (eql 'coalton:define)) whole)
  (multiple-value-bind (name expr) (parse-define-form whole)
    (cond
      ((var-definedp name)
       ;; XXX: Get this right. Re-typecheck everything?!
       (let ((internal-name (entry-internal-name (var-info name))))
         `(setf ,internal-name ,(compile-value-to-lisp expr))))
      (t
       (unless (var-knownp name)
         ;; Declare the variable.
         (forward-declare-variable name))
       ;; Do some type inferencing.
       (let ((inferred-type (derive-type expr))
             (internal-name (entry-internal-name (var-info name))))
         ;; FIXME check VAR-DECLARED-TYPE
         ;; FIXME check VAR-DERIVED-TYPE
         (setf (var-derived-type name)             inferred-type
               (entry-source-form (var-info name)) whole
               (entry-node (var-info name))        expr)
         `(progn
            (define-symbol-macro ,name ,internal-name)
            (global-vars:define-global-var ,internal-name ,(compile-value-to-lisp expr))
            ',name))))))


;;; Entry Point

(defun flatten-toplevel-forms (forms)
  (loop :for form :in forms
        :append (cond
                  ((atom form) (list form))
                  ((member (first form) **toplevel-operators**)
                   (flatten-toplevel-forms (rest form)))
                  (t (list form)))))

(defun process-coalton-toplevel-forms (forms)
  `(progn ,@(mapcar #'compile-toplevel-form forms)))


;;; Coalton Macros

(defmacro coalton:coalton (&body toplevel-forms)
  (process-coalton-toplevel-forms (flatten-toplevel-forms toplevel-forms)))
