; 			Checking of a AND-LET* special form
;
; AND-LET* is a generalized AND: it evaluates a sequence of forms one after another
; till the first one that yields #f; the non-#f result of a form can be bound
; to a fresh variable and used in the subsequent forms.
;
; When an ordinary AND is formed of _proper_ boolean expressions:
;	(AND E1 E2 ...)
; expression E2, if it gets to be evaluated, knows that E1 has returned non-#f.
; Moreover, E2 knows exactly what the result of E1 was - #t - so E2 can use
; this knowledge to its advantage. If E1 however is an _extended_
; boolean expression, E2 can no longer tell which particular non-#f
; value E1 has returned. Chances are it took a lot of work to evaluate E1,
; and the produced result (a number, a vector, a string, etc) may be of
; value to E2. Alas, the AND form merely checks that the result is not an #f,
; and throws it away. If E2 needs it, it has to recompute the value again.
; This proposed AND-LET* special form lets constituent expressions get
; hold of the results of already evaluated expressions, without re-doing
; their work.
;
; Syntax:
; 	AND-LET* (CLAWS) BODY
;
; where CLAWS is a list of expressions or bindings: 
;	CLAWS ::= '() | (cons CLAW CLAWS)
; Every element of the CLAWS list, a CLAW, must be one of the following:
;	(VARIABLE EXPRESSION)
; or
;	(EXPRESSION)
; or
;	BOUND-VARIABLE
; These CLAWS are evaluated in the strict left-to-right order. For each
; CLAW, the EXPRESSION part is evaluated first (or BOUND-VARIABLE is looked up).
; If the result is #f, AND-LET* immediately returns #f, thus disregarding the rest
; of the CLAWS and the BODY. If the EXPRESSION evaluates to not-#f, and
; the CLAW is of the form
;	(VARIABLE EXPRESSION)
; the EXPRESSION's value is bound to a freshly made VARIABLE. The VARIABLE is
; available for _the rest_ of the CLAWS, and the BODY. As usual, all
; VARIABLEs must be unique (like in let*).
;
; Thus AND-LET* is a sort of cross-breed between LET* and AND.
;
; Denotation semantics:
;
; Eval[ (AND-LET* (CLAW1 ...) BODY), Env] =
;	EvalClaw[ CLAW1, Env ] andalso 
;		Eval[ (AND-LET* ( ...) BODY), ExtClawEnv[ CLAW1, Env]]
;
; Eval[ (AND-LET* (CLAW) ), Env] = EvalClaw[ CLAW, Env ]
; Eval[ (AND-LET* () FORM1 ...), Env] = Eval[ (BEGIN FORM1 ...), Env ]
; Eval[ (AND-LET* () ), Env] = #t
;
; EvalClaw[ BOUND-VARIABLE, Env ] = Eval[ BOUND-VARIABLE, Env ]
; EvalClaw[ (EXPRESSION), Env ] = Eval[ EXPRESSION, Env ]
; EvalClaw[ (VARIABLE EXPRESSION), Env ] = Eval[ EXPRESSION, Env ]
;
; ExtClawEnv[ BOUND-VARIABLE, Env ] = Env
; ExtClawEnv[ (EXPRESSION), Env ] = EnvAfterEval[ EXPRESSION, Env ]
; ExtClawEnv[ (VARIABLE EXPRESSION), Env ] = 
;	ExtendEnv[ EnvAfterEval[ EXPRESSION, Env ],
;		   VARIABLE boundto Eval[ EXPRESSION, Env ]]
;
;
; If one has a Scheme interpreter written in Prolog/ML/Haskell, he can
; implement the above semantics right away. Within Scheme, it is trivial to
; code AND-LET* with R4RS "define-syntax". Alas, Gambit does not have this
; facility. So this implementation uses macros instead.
;
; The following AND-LET* macro will convert a AND-LET* expression into a "tree" of
; AND and LET expressions. For example,
; (AND-LET* ((my-list (compute-list)) ((not (null? my-list))))
;	(do-something my-list))
; is transformed into
; (and (let ((my-list (compute-list)))
;	(and my-list  (not (null? my-list)) (begin (do-something my-list)))))
;
; I must admit the AND-LET* macro is written in a pathetic anti-functional style.
; To my excuse, the macro's goal is a syntactic transformation of source
; code, that is, performing a re-writing. IMHO, rewriting kind of suggests
; mutating.
;
; Sample applications:
;
; The following piece of code (from my treap package) 
;   (let ((new-root (node:dispatch-on-key root key ...)))
;      (if new-root (set! root new-root)))
; could be elegantly re-written as
;   (and-let* ((new-root (node:dispatch-on-key root key ...)))
;		(set! root new-root))
;
; A very common application of and-let* is looking up a value
; associated with a given key in an assoc list, returning #f in case of a
; look-up failure:
;
;		; Standard implementation
; (define (look-up key alist)
;   (let ((found-assoc (assq key alist)))
;	(and found-assoc (cdr found-assoc))))
;
; 		; A more elegant solution
; (define (look-up key alist)
;   (cdr (or (assq key alist) '(#f . #f))))
;
; 		; An implementation which is just as graceful as the latter
;		; and just as efficient as the former:
; (define (look-up key alist)
;   (and-let* ((x (assq key alist))) (cdr x)))
;
; Generalized cond:
;
; (or
;   (and-let* (bindings-cond1) body1)
;   (and-let* (bindings-cond2) body2)
;   (begin else-clause))
;
; Unlike => (cond's send), AND-LET* applies beyond cond. AND-LET* can also be used
; to generalize cond, as => is limited to sending of only a single value;
; AND-LET* allows as many bindings as necessary (which are performed in sequence)
;
; (or
;  (and-let* ((c (read-char)) ((not (eof-object? c))))
;	(string-set! some-str i c) (++! i))
;  (begin (do-process-eof)))
;
; Another concept AND-LET* is reminiscent of is programming with guards:
; a AND-LET* form can be considered a sequence of _guarded_ expressions.
; In a regular program, forms may produce results, bind them to variables
; and let other forms use these results. AND-LET* differs in that it checks
; to make sure that every produced result "makes sense" (that is, not an #f).
; The first "failure" triggers the guard and aborts the rest of the
; sequence (which presumably would not make any sense to execute anyway).
;
; $Id: ref.scm,v 1.4 2005/02/18 21:58:30 donovan Exp $


(define-macro (and-let* claws . body)
  (let* ((new-vars '())
  (result (cons 'and '()))
  (growth-point result))

    (define (syntax-error msg arg)
      (error "and-let* ~a ~a" msg (list arg)))
    (define (andjoin! clause)
      (let ((prev-point growth-point)
     (clause-cell (cons clause '())))
        (set-cdr! growth-point clause-cell)
        (set! growth-point clause-cell)))

    (if (not (list? claws))
      (syntax error "Bindings are not a list: %s" claws))
    (for-each
      (lambda (claw)
        (cond
          ((symbol? claw)            ; BOUND-VARIABLE form
    (andjoin! claw))
          ((and (pair? claw) (null? (cdr claw)))  ; (EXPRESSION) form
    (andjoin! (car claw)))
          ((and (pair? claw) (symbol? (car claw)) ; (VARIABLE EXPRESSION) form
  (pair? (cdr claw)) (null? (cddr claw)))
    (let* ((var (car claw))
    (var-cell (cons var '())))
      (if (memq var new-vars)
   (syntax-error "Duplicate variable in bindings: %s" var))
      (set! new-vars (cons var new-vars))
      (set-cdr! growth-point `((let (,claw) (and . ,var-cell))))
      (set! growth-point var-cell)))
          (else
            (syntax-error "Ill-formed binding: %s" claw))))
      claws)
    (if (not (null? body))
 (if (null? (cdr body))
     (andjoin! (car body))
     (andjoin! `(begin ,@body))))
;    (newline) (display result) (newline)  ; uncomment to show expansion
    result))
