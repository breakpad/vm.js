Visitor = require '../ast/visitor'
{StopIteration, ArrayIterator} = require '../runtime/util'
{VmTypeError} = require '../runtime/errors'
{VmObject} = require '../runtime/internal'
{Closure, Scope} = require './thread'

OpcodeClassFactory = (->
  # opcode id, correspond to the index in the opcodes array and is used
  # to represent serialized opcodes
  id = 0

  classFactory = (name, fn, calculateFactor) ->
    # generate opcode class
    OpcodeClass = (->
      # this is ugly but its the only way I found to get nice opcode
      # names when debugging with node-inspector/chrome dev tools
      constructor = eval(
        "(function #{name}(args) { if (args) this.args = args; })")
      constructor::id = id++
      constructor::name = name
      constructor::exec = fn
      if calculateFactor
        constructor::calculateFactor = calculateFactor
      else
        constructor::factor = calculateOpcodeFactor(fn)
        constructor::calculateFactor = -> @factor
      return constructor
    )()
    return OpcodeClass
  return classFactory
)()

# Each opcode has a stack depth factor which is the maximum size that the
# opcode will take the evaluation stack to, and is used later to
# determine the maximum stack size needed for running a script
#
# In most cases this number is static and depends only on the opcode function
# body. To avoid having to maintain the number manually, we parse the opcode
# source and count the number of pushes - pops by transversing the ast. This
# is hacky but seems to do the job
class Counter extends Visitor
  constructor: ->
    @factor = 0
    @current = 0

  CallExpression: (node) ->
    node = super(node)
    if node.callee.type is 'MemberExpression'
      if node.callee.property.type is 'Identifier'
        name =  node.callee.property.name
      else if node.callee.property.type is 'Literal'
        name =  node.callee.property.value
      else
        throw new Error('assert error')
      if name is 'push'
        @current++
      else if name is 'pop'
        @current--
      @factor = Math.max(@factor, @current)
    return node


calculateOpcodeFactor = (opcodeFn) ->
  ast = esprima.parse("(#{opcodeFn.toString()})")
  counter = new Counter()
  counter.visit(ast)
  return counter.factor


Op = (name, fn, factorFn) -> OpcodeClassFactory(name, fn, factorFn)


opcodes = [
  Op 'POP', (f, s, l) -> s.pop()                      # remove top
  Op 'DUP', (f, s, l) -> s.push(s.top())              # duplicate top
  Op 'RET', (f, s, l) -> ret(f)                       # return from function
  Op 'RETV', (f, s, l) ->                             # return value from
    f.fiber.rv = s.pop()                              # function
    ret(f)

  Op 'THROW', (f, s, l) ->                            # throw something
    f.fiber.error = s.pop()
    f.paused = true

  Op 'DEBUG', (f, s, l) -> debug()                    # pause execution
  Op 'SR1', (f, s, l) -> f.r1 = s.pop()               # save to register 1
  Op 'SR2', (f, s, l) -> f.r2 = s.pop()               # save to register 2
  Op 'SR3', (f, s, l) -> f.r3 = s.pop()               # save to register 3
  Op 'SR4', (f, s, l) -> f.r4 = s.pop()               # save to register 4
  Op 'LR1', (f, s, l) -> s.push(f.r1)                 # load from register 1
  Op 'LR2', (f, s, l) -> s.push(f.r2)                 # load from register 2
  Op 'LR3', (f, s, l) -> s.push(f.r3)                 # load from register 3
  Op 'LR4', (f, s, l) -> s.push(f.r4)                 # load from register 4
  Op 'SREXP', (f, s, l) -> s.rexp = s.pop()           # save to the
                                                      # expression register

  Op 'ITER', (f, s, l) ->                             # calls 'iterator' method
    callm(f, s, 0, 'iterator', s.pop())

  Op 'ENUMERATE', (f, s, l, c) ->                     # push iterator that
    target = s.pop()                                  # yields the object
    if target instanceof VmObject                     # enumerable properties
      iterator = target.enumerate()
    else
      keys = []
      for k of target
        keys.push(k)
      iterator = new ArrayIterator(keys)
    s.push(c.createObject(iterator))

  Op 'NEXT', (f, s, l) ->                             # calls iterator 'next'
    callm(f, s, 0, 'next', s.pop())
    if f.fiber.error == StopIteration
      f.paused = false
      f.ip = @args[0]

  Op 'ARGS', (f, s, l) ->                             # prepare the 'arguments'
    l.set(0, s.pop())                                 # object
    # the fiber pushing the arguments object cancels
    # this opcode pop calL
  , -> 0

  Op 'REST', (f, s, l, c) ->                          # initialize 'rest' param
    index = @args[0]
    varIndex = @args[1]
    args = l.get(0).container
    if index < args.length
      l.set(varIndex, c.createArray(Array::slice.call(args, index)))

  Op 'CALL', (f, s, l) ->                             # call function
    call(f, s, @args[0], s.pop())
     # pop n arguments plus function and push return value
  , -> 1 - (@args[0] + 1)

  Op 'CALLM', (f, s, l) ->                            # call method
    callm(f, s, @args[0], s.pop(), s.pop())
     # pop n arguments plus function plus target and push return value
  , -> 1 - (@args[0] + 1 + 1)

  Op 'GET', (f, s, l, c) ->                           # get property from
    obj = s.pop()                                     # object
    key = s.pop()
    if obj instanceof VmObject
      val = obj.get(key)
    else
      proto = c.getNativePrototype(obj)
      if not proto
        throw new Error('assert error')
      val = proto.get(key, obj)
    s.push(val)

  Op 'SET', (f, s, l, c) ->                           # set property on
    obj = s.pop()                                     # object
    key = s.pop()
    val = s.pop()
    if obj instanceof VmObject
      obj.set(key, val)
    else
      proto = c.getNativePrototype(obj)
      if not proto
        throw new Error('assert error')
      proto.set(key, val, obj)
    s.push(val)

  Op 'DEL', (f, s, l) ->                              # del property on
    obj = s.pop()                                     # object
    if obj instanceof VmObject
      obj.del(key)
    else
      proto = c.getNativePrototype(obj)
      if not proto
        throw new Error('assert error')
      proto.del(key, obj)
    s.push(true) # is this correct?

  Op 'GETL', (f, s, l) ->                             # get local variable
    scopeIndex = @args[0]
    varIndex = @args[1]
    scope = l
    while scopeIndex--
      scope = scope.parent
    s.push(scope.get(varIndex))

  Op 'SETL', (f, s, l) ->                             # set local variable
    scopeIndex = @args[0]
    varIndex = @args[1]
    scope = l
    while scopeIndex--
      scope = scope.parent
    s.push(scope.set(varIndex, s.pop()))

  Op 'GETG', (f, s, l, c) ->                          # get global variable
    s.push(c.global[@args[0]])

  Op 'SETG', (f, s, l, c) ->                          # set global variable
    s.push(c.global[@args[0]] = s.pop())

  Op 'ENTER_SCOPE', (f) ->                            # enter nested scope
    if not f.scope
      # block inside global scope
      f.scope = new Scope(null, f.script.localNames, f.script.localLength)

  Op 'EXIT_SCOPE', (f) -> f.scope = f.scope.parent    # exit nested scope

  Op 'INV', (f, s, l) -> s.push(-s.pop())             # invert signal
  Op 'LNOT', (f, s, l) -> s.push(not s.pop())         # logical NOT
  Op 'NOT', (f, s, l) -> s.push(~s.pop())             # bitwise NOT
  Op 'INC', (f, s, l) -> s.push(s.pop() + 1)          # increment
  Op 'DEC', (f, s, l) -> s.push(s.pop() - 1)          # decrement

  Op 'ADD', (f, s, l) -> s.push(s.pop() + s.pop())    # sum
  Op 'SUB', (f, s, l) -> s.push(s.pop() - s.pop())    # difference
  Op 'MUL', (f, s, l) -> s.push(s.pop() * s.pop())    # product
  Op 'DIV', (f, s, l) -> s.push(s.pop() / s.pop())    # division
  Op 'MOD', (f, s, l) -> s.push(s.pop() % s.pop())    # modulo
  Op 'SHL', (f, s, l) ->  s.push(s.pop() << s.pop())  # left shift
  Op 'SAR', (f, s, l) -> s.push(s.pop() >> s.pop())   # right shift
  Op 'SHR', (f, s, l) -> s.push(s.pop() >>> s.pop())  # unsigned right shift
  Op 'OR', (f, s, l) -> s.push(s.pop() | s.pop())     # bitwise OR
  Op 'AND', (f, s, l) -> s.push(s.pop() & s.pop())    # bitwise AND
  Op 'XOR', (f, s, l) -> s.push(s.pop() ^ s.pop())    # bitwise XOR

  Op 'CEQ', (f, s, l) -> s.push(`s.pop() == s.pop()`) # equals
  Op 'CNEQ', (f, s, l) -> s.push(`s.pop() != s.pop()`)# not equals
  Op 'CID', (f, s, l) -> s.push(s.pop() is s.pop())   # same
  Op 'CNID', (f, s, l) -> s.push(s.pop() isnt s.pop())# not same
  Op 'LT', (f, s, l) -> s.push(s.pop() < s.pop())     # less than
  Op 'LTE', (f, s, l) -> s.push(s.pop() <= s.pop())   # less or equal than
  Op 'GT', (f, s, l) -> s.push(s.pop() > s.pop())     # greater than
  Op 'GTE', (f, s, l) -> s.push(s.pop() >= s.pop())   # greater or equal than
  Op 'IN', (f, s, l) -> s.push(s.pop() of s.pop())    # contains property
  Op 'INSTANCE_OF', (f, s, l) ->                      # instance of
    s.push(s.pop() instanceof s.pop())

  Op 'JMP', (f, s, l) -> f.ip = @args[0]              # unconditional jump
  Op 'JMPT', (f, s, l) -> f.ip = @args[0] if s.pop()  # jump if true
  Op 'JMPF', (f, s, l) -> f.ip = @args[0] if not s.pop()# jump if false

  Op 'LITERAL', (f, s, l) ->                          # push literal value
    s.push(@args[0])

  Op 'OBJECT_LITERAL', (f, s, l, c) ->                # object literal
    length = @args[0]
    rv = {}
    while length--
      rv[s.pop()] = s.pop()
    s.push(c.createObject(rv))
    # pops one item for each key/value and push the object
  , -> 1 - (@args[0] * 2)

  Op 'ARRAY_LITERAL', (f, s, l, c) ->                 # array literal
    length = @args[0]
    rv = new Array(length)
    while length--
      rv[length] = s.pop()
    s.push(c.createArray(rv))
     # pops each element and push the array
  , -> 1 - @args[0]

  Op 'FUNCTION', (f, s, l) ->                         # push function reference
    # get the index of the script with function code
    scriptIndex = @args[0]
    # create a new closure, passing the current local scope
    fn = new Closure(f.script.scripts[scriptIndex], l)
    s.push(fn)
]


# Helpers shared between some opcodes
callm = (frame, stack, length, key, target) ->
  if target instanceof VmObject
    func = target.get(key)
    if func instanceof Closure
      return call(frame, stack, length, func, target)
    if func instanceof Function
      return call(frame, stack, length, func, target.container)
    if not func?
      err = new VmTypeError("Object #{@container} has no method '#{key}'")
    else
      err = new VmTypeError(
        "Property '#{key}' of object #{@container} is not a function")
      frame.fiber.error = err
      frame.paused = true
  else
    call(frame, stack, length, target[key], target)

call = (frame, stack, length, func, target) ->
  if not (func instanceof Closure) and not (func instanceof Function)
    frame.fiber.error = new VmTypeError("Object #{func} is not a function")
    frame.paused = true
    return
  args = {length: length, callee: func}
  while length
    args[--length] = stack.pop()
  if func instanceof Function
    # 'native' function, execute and push to the evaluation stack
    try
      stack.push(func.apply(target, Array::slice.call(args)))
    catch nativeError
      frame.paused = true
      frame.fiber.error = nativeError
  else
    # TODO set context
    frame.paused = true
    frame.fiber.pushFrame(func, frame.context.createObject(args))


ret = (frame) ->
  if frame.finalizer
    frame.ip = frame.finalizer
    frame.finalizer = null
  else
    frame.ip = frame.exitIp

debug = ->

module.exports = opcodes