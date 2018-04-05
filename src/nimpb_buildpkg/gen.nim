import macros
import strutils

import nimpb/nimpb

type
    MessageDesc* = object
        name*: string
        fields*: seq[FieldDesc]
        oneofs*: seq[string]

    FieldLabel* {.pure.} = enum
        Optional = 1
        Required
        Repeated

    FieldDesc* = object
        name*: string
        number*: int
        ftype*: FieldType
        label*: FieldLabel
        typeName*: string
        packed*: bool
        oneofIdx*: int

    EnumDesc* = object
        name*: string
        values*: seq[EnumValueDesc]

    EnumValueDesc* = object
        name*: string
        number*: int

proc findColonExpr(parent: NimNode, s: string): NimNode =
    for child in parent:
        if child.kind != nnkExprColonExpr:
            continue

        if $child[0] == s:
            return child

proc getMessageName(desc: NimNode): string =
    let node = findColonExpr(desc, "name")
    result = $node[1]

iterator fields(desc: NimNode): NimNode =
    let node = findColonExpr(desc, "fields")
    for field in node[1]:
        yield field

proc isRepeated(field: NimNode): bool =
    let node = findColonExpr(field, "label")
    let value = FieldLabel(node[1].intVal)
    result = value == FieldLabel.Repeated

proc isPacked(field: NimNode): bool =
    let node = findColonExpr(field, "packed")
    result = bool(node[1].intVal)

proc getFieldType(field: NimNode): FieldType =
    let node = findColonExpr(field, "ftype")
    result = FieldType(node[1].intVal)

proc isMessage(field: NimNode): bool =
    result = getFieldType(field) == FieldType.Message

proc isEnum(field: NimNode): bool =
    result = getFieldType(field) == FieldType.Enum

proc getFieldTypeName(field: NimNode): string =
    let node = findColonExpr(field, "typeName")
    result = $node[1]

proc getFieldTypeAsString(field: NimNode): string =
    if isMessage(field) or isEnum(field):
        result = getFieldTypeName(field)
    else:
        case getFieldType(field)
        of FieldType.Double: result = "float64"
        of FieldType.Float: result = "float32"
        of FieldType.Int64: result = "int64"
        of FieldType.UInt64: result = "uint64"
        of FieldType.Int32: result = "int32"
        of FieldType.Fixed64: result = "uint64"
        of FieldType.Fixed32: result = "uint32"
        of FieldType.Bool: result = "bool"
        of FieldType.String: result = "string"
        of FieldType.Bytes: result = "bytes"
        of FieldType.UInt32: result = "uint32"
        of FieldType.SFixed32: result = "int32"
        of FieldType.SFixed64: result = "int64"
        of FieldType.SInt32: result = "int32"
        of FieldType.SInt64: result = "int64"
        else: result = "AYBABTU"

proc getFullFieldType(field: NimNode): NimNode =
    result = ident(getFieldTypeAsString(field))
    if isRepeated(field):
        result = nnkBracketExpr.newTree(ident("seq"), result)

proc getFieldName(field: NimNode): string =
    let node = findColonExpr(field, "name")
    result = $node[1]

proc getFieldNumber(field: NimNode): int =
    result = int(findColonExpr(field, "number")[1].intVal)

proc defaultValue(field: NimNode): NimNode =
    # TODO: check if there is a default value specified for the field

    if isRepeated(field):
        return nnkPrefix.newTree(newIdentNode("@"), nnkBracket.newTree())

    case getFieldType(field)
    of FieldType.Double: result = newLit(0.0'f64)
    of FieldType.Float: result = newLit(0.0'f32)
    of FieldType.Int64: result = newLit(0'i64)
    of FieldType.UInt64: result = newLit(0'u64)
    of FieldType.Int32: result = newLit(0'i32)
    of FieldType.Fixed64: result = newLit(0'u64)
    of FieldType.Fixed32: result = newLit(0'u32)
    of FieldType.Bool: result = newLit(false)
    of FieldType.String: result = newLit("")
    of FieldType.Group: result = newLit("NOTIMPLEMENTED")
    of FieldType.Message: result = newCall(ident("new" & getFieldTypeAsString(field)))
    of FieldType.Bytes: result = newCall(ident("bytes"), newLit(""))
    of FieldType.UInt32: result = newLit(0'u32)
    of FieldType.Enum:
        let
            descId = ident(getFieldTypeAsString(field) & "Desc")
            nameId = ident(getFieldTypeAsString(field))
        result = quote do:
            `nameId`(`descId`.values[0].number)
    of FieldType.SFixed32: result = newLit(0'u32)
    of FieldType.SFixed64: result = newLit(0'u32)
    of FieldType.SInt32: result = newLit(0)
    of FieldType.SInt64: result = newLit(0)

proc wiretype(field: NimNode): WireType =
    result = wiretype(getFieldType(field))

# TODO: maybe not the best name for this
proc getFieldNameAST(objname: NimNode, field: NimNode, oneof: string): NimNode =
    result =
        if oneof != "":
            newDotExpr(newDotExpr(objname, ident(oneof)), ident(getFieldName(field)))
        else:
            newDotExpr(objname, ident(getFieldName(field)))

proc fieldInitializer(objname: NimNode, field: NimNode, oneof: string): NimNode =
    result = nnkAsgn.newTree(
        getFieldNameAST(objname, field, oneof),
        defaultValue(field)
    )

proc oneofIndex(field: NimNode): int =
    let node = findColonExpr(field, "oneofIdx")
    if node == nil:
        result = -1
    else:
        result = int(node[1].intVal)

proc oneofName(message, field: NimNode): string =
    let index = oneofIndex(field)

    if index == -1:
        return ""

    let oneofs = findColonExpr(message, "oneofs")[1]

    result = $oneofs[index]

iterator oneofFields(message: NimNode, index: int): NimNode =
    if index != -1:
        for field in fields(message):
            if oneofIndex(field) == index:
                yield field

proc generateOneofFields*(desc: NimNode, typeSection: NimNode) =
    let
        oneofs = findColonExpr(desc, "oneofs")[1]
        messageName = getMessageName(desc)

    for index, oneof in oneofs:
        let reclist = nnkRecList.newTree()

        for field in oneofFields(desc, index):
            let ftype = getFullFieldType(field)
            let name = ident(getFieldName(field))

            add(reclist, newIdentDefs(postfix(name, "*"), ftype))

        let typedef = nnkTypeDef.newTree(
            nnkPragmaExpr.newTree(
                postfix(ident(messageName & $oneof), "*"),
                nnkPragma.newTree(
                    ident("union")
                )
            ),
            newEmptyNode(),
            nnkObjectTy.newTree(
                newEmptyNode(),
                newEmptyNode(),
                reclist
            )
        )

        add(typeSection, typedef)

macro generateMessageType*(desc: typed): typed =
    let
        impl = getImpl(symbol(desc))
        typeSection = nnkTypeSection.newTree()
        typedef = nnkTypeDef.newTree()
        reclist = nnkRecList.newTree()
        oneofs = findColonExpr(impl, "oneofs")[1]

    let name = getMessageName(impl)

    let typedefRef = nnkTypeDef.newTree(postfix(newIdentNode(name), "*"), newEmptyNode(),
        nnkRefTy.newTree(newIdentNode(name & "Obj")))
    add(typeSection, typedefRef)

    add(typeSection, typedef)

    add(typedef, postfix(ident(name & "Obj"), "*"))
    add(typedef, newEmptyNode())
    add(typedef, nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), reclist))

    for field in fields(impl):
        let ftype = getFullFieldType(field)
        let name = ident(getFieldName(field))
        if oneofIndex(field) == -1:
            add(reclist, newIdentDefs(postfix(name, "*"), ftype))

    for oneof in oneofs:
        add(reclist, newIdentDefs(postfix(ident($oneof), "*"),
            ident(name & $oneof)))

    add(reclist, nnkIdentDefs.newTree(
        ident("hasField"), ident("IntSet"), newEmptyNode()))

    generateOneofFields(impl, typeSection)

    result = newStmtList()
    add(result, typeSection)

    when defined(debug):
        hint(repr(result))

proc generateNewMessageProc(desc: NimNode): NimNode =
    let
        body = newStmtList(
            newCall(ident("new"), ident("result"))
        )
        resultId = ident("result")

    for field in fields(desc):
        let oneofName = oneofName(desc, field)
        add(body, fieldInitializer(resultId, field, oneofName))

    add(body, newAssignment(newDotExpr(resultId, ident("hasField")),
        newCall(ident("initIntSet"))))

    result = newProc(postfix(ident("new" & getMessageName(desc)), "*"),
        @[ident(getMessageName(desc))],
        body)

proc fieldProcName(prefix: string, field: NimNode): string =
    result = prefix & capitalizeAscii(getFieldName(field))

proc fieldProcIdent(prefix: string, field: NimNode): NimNode =
    result = postfix(ident(fieldProcName(prefix, field)), "*")

proc generateClearFieldProc(desc, field: NimNode): NimNode =
    let
        messageId = ident("message")
        fname = getFieldNameAST(messageId, field, oneofName(desc, field))
        defvalue = defaultValue(field)
        hasField = newDotExpr(messageId, ident("hasField"))
        number = getFieldNumber(field)
        procName = fieldProcIdent("clear", field)
        mtype = ident(getMessageName(desc))

    result = quote do:
        proc `procName`(`messageId`: `mtype`) =
            `fname` = `defvalue`
            excl(`hasfield`, `number`)

    # When clearing a field that is contained in a oneof, we should also clear
    # the other fields.
    for sibling in oneofFields(desc, oneofIndex(field)):
        if sibling == field:
            continue
        let
            number = getFieldNumber(sibling)
            exclNode = quote do:
                excl(`hasField`, `number`)
        add(body(result), exclNode)

proc generateHasFieldProc(desc, field: NimNode): NimNode =
    let
        messageId = ident("message")
        hasField = newDotExpr(messageId, ident("hasField"))
        number = getFieldNumber(field)
        mtype = ident(getMessageName(desc))
        procName = fieldProcIdent("has", field)

    result = quote do:
        proc `procName`(`messageId`: `mtype`): bool =
            contains(`hasfield`, `number`)

proc generateSetFieldProc(desc, field: NimNode): NimNode =
    let
        messageId = ident("message")
        hasField = newDotExpr(messageId, ident("hasField"))
        number = getFieldNumber(field)
        valueId = ident("value")
        fname = getFieldNameAST(messageId, field, oneofName(desc, field))
        procName = fieldProcIdent("set", field)
        mtype = ident(getMessageName(desc))
        ftype = getFullFieldType(field)

    result = quote do:
        proc `procName`(`messageId`: `mtype`, `valueId`: `ftype`) =
            `fname` = `valueId`
            incl(`hasfield`, `number`)

    # When setting a field that is in a oneof, we need to unset the other fields
    for sibling in oneofFields(desc, oneofIndex(field)):
        if sibling == field:
            continue
        let
            number = getFieldNumber(sibling)
            exclNode = quote do:
                excl(`hasField`, `number`)
        add(body(result), exclNode)

proc generateAddToFieldProc(desc, field: NimNode): NimNode =
    let
        procName = fieldProcIdent("add", field)
        messageId = ident("message")
        mtype = ident(getMessageName(desc))
        valueId = ident("value")
        ftype = ident(getFieldTypeAsString(field))
        hasField = newDotExpr(messageId, ident("hasField"))
        number = getFieldNumber(field)
        fname = newDotExpr(messageId, ident(getFieldName(field)))

    result = quote do:
        proc `procName`(`messageId`: `mtype`, `valueId`: `ftype`) =
            add(`fname`, `valueId`)
            incl(`hasfield`, `number`)

proc ident(wt: WireType): NimNode =
    result = newDotExpr(ident("WireType"), ident($wt))

proc genWriteField(message, field: NimNode): NimNode =
    result = newStmtList()

    let
        number = getFieldNumber(field)
        writer = ident("write" & getFieldTypeAsString(field))
        messageId = ident("message")
        fname = getFieldNameAST(messageId, field, oneofName(message, field))
        wiretype = ident(wiretype(field))
        sizeproc = ident("sizeOf" & getFieldTypeAsString(field))
        hasproc = ident(fieldProcName("has", field))

    if not isRepeated(field):
        result.add quote do:
            if `hasproc`(message):
                writeTag(stream, `number`, `wiretype`)
                `writer`(stream, `fname`)
        if isMessage(field):
            insert(result[0][0][1], 1, quote do:
                writeVarint(stream, `sizeproc`(`fname`))
            )
    else:
        let valueId = ident("value")
        if isPacked(field):
            result.add quote do:
                writeTag(stream, `number`, WireType.LengthDelimited)
                writeVarInt(stream, packedFieldSize(`fname`, `wiretype`))
                for `valueId` in `fname`:
                    `writer`(stream, `valueId`)
        else:
            result.add quote do:
                for `valueId` in `fname`:
                    writeTag(stream, `number`, `wiretype`)
                    `writer`(stream, `valueId`)
            if isMessage(field):
                insert(result[^1][^1], 1, quote do:
                    writeVarint(stream, `sizeproc`(`valueId`))
                )

proc generateWriteMessageProc(desc: NimNode): NimNode =
    let
        messageId = ident("message")
        mtype = ident(getMessageName(desc))
        procName = postfix(ident("write" & getMessageName(desc)), "*")
        body = newStmtList()
        stream = ident("stream")
        sizeproc = postfix(ident("sizeOf" & getMessageName(desc)), "*")

    for field in fields(desc):
        add(body, genWriteField(desc, field))

    result = quote do:
        proc `sizeproc`(`messageId`: `mtype`): uint64

        proc `procName`(`stream`: ProtobufStream, `messageId`: `mtype`) =
            `body`

proc generateReadMessageProc(desc: NimNode): NimNode =
    let
        procName = postfix(ident("read" & getMessageName(desc)), "*")
        newproc = ident("new" & getMessageName(desc))
        streamId = ident("stream")
        mtype = ident(getMessageName(desc))
        tagId = ident("tag")
        wiretypeId = ident("wiretype")
        resultId = ident("result")

    result = quote do:
        proc `procName`(`streamId`: ProtobufStream): `mtype` =
            `resultId` = `newproc`()
            while not atEnd(stream):
                let
                    `tagId` = readTag(`streamId`)
                    `wiretypeId` = wireType(`tagId`)
                case fieldNumber(`tagId`)
                else:
                    skipField(`streamId`, `wiretypeId`)

    let caseNode = body(result)[1][1][1]

    # TODO: check wiretypes and fail if it doesn't match
    for field in fields(desc):
        let
            number = getFieldNumber(field)
            reader = ident("read" & getFieldTypeAsString(field))
            setproc =
                if isRepeated(field):
                    ident("add" & capitalizeAscii(getFieldName(field)))
                else:
                    ident("set" & capitalizeAscii(getFieldName(field)))
        if isRepeated(field):
            if isNumeric(getFieldType(field)):
                insert(caseNode, 1, nnkOfBranch.newTree(newLit(number), quote do:
                    if `wiretypeId` == WireType.LengthDelimited:
                        let
                            size = readVarint(stream)
                            start = getPosition(stream).uint64
                        var consumed = 0'u64
                        while consumed < size:
                            `setproc`(`resultId`, `reader`(stream))
                            consumed = getPosition(stream).uint64 - start
                        if consumed != size:
                            raise newException(Exception, "packed field size mismatch")
                    else:
                        `setproc`(`resultId`, `reader`(stream))
                ))
            elif isMessage(field):
                insert(caseNode, 1, nnkOfBranch.newTree(newLit(number), quote do:
                    let size = readVarint(stream)
                    let data = readStr(stream, int(size))
                    let stream2 = newProtobufStream(newStringStream(data))
                    `setproc`(`resultId`, `reader`(stream2))
                ))
            else:
                insert(caseNode, 1, nnkOfBranch.newTree(newLit(number), quote do:
                    `setproc`(`resultId`, `reader`(stream))
                ))
        else:
            if isMessage(field):
                insert(caseNode, 1, nnkOfBranch.newTree(newLit(number), quote do:
                    let size = readVarint(stream)
                    let data = readStr(stream, int(size))
                    let stream2 = newProtobufStream(newStringStream(data))
                    `setproc`(`resultId`, `reader`(stream2))
                ))
            else:
                insert(caseNode, 1, nnkOfBranch.newTree(newLit(number), quote do:
                    `setproc`(`resultId`, `reader`(stream))
                ))

proc generateSizeOfMessageProc(desc: NimNode): NimNode =
    let
        name = getMessageName(desc)
        body = newStmtList()
        messageId = ident("message")
        resultId = ident("result")
        procName = postfix(ident("sizeOf" & getMessageName(desc)), "*")
        mtype = ident(getMessageName(desc))

    result = quote do:
        proc `procName`(`messageId`: `mtype`): uint64 =
            `resultId` = 0

    let procBody = body(result)

    for field in fields(desc):
        let
            hasproc = ident(fieldProcName("has", field))
            sizeofproc = ident("sizeOf" & getFieldTypeAsString(field))
            fname = getFieldNameAST(messageId, field, oneofName(desc, field))
            number = getFieldNumber(field)
            wiretype = ident(wiretype(field))

        # TODO: packed
        if isRepeated(field):
            if isPacked(field):
                procBody.add quote do:
                    if `hasproc`(`messageId`):
                        let
                            tagSize = sizeOfUint32(uint32(makeTag(`number`, WireType.LengthDelimited)))
                            dataSize = packedFieldSize(`fname`, `wiretype`)
                            sizeOfSize = sizeOfUint64(dataSize)
                        `resultId` = tagSize + dataSize + sizeOfSize
            else:
                procBody.add quote do:
                    for value in `fname`:
                        let
                            sizeOfField = `sizeofproc`(value)
                            tagSize = sizeOfUint32(uint32(makeTag(`number`, `wiretype`)))
                        `resultId` = `resultId` +
                            sizeOfField +
                            sizeOfUint64(sizeOfField) +
                            tagSize
        else:
            let sizeOfFieldId = ident("sizeOfField")

            procBody.add quote do:
                if `hasproc`(`messageId`):
                    let
                        `sizeOfFieldId` = `sizeofproc`(`fname`)
                        tagSize = sizeOfUint32(uint32(makeTag(`number`, `wiretype`)))
                    `resultId` = `resultId` + sizeOfField + tagSize

            if isMessage(field):
                # For messages we need to include the size of the encoded size
                let asgn = procBody[^1][0][1][1]
                asgn[1] = infix(asgn[1], "+", newCall(ident("sizeOfUint64"),
                    sizeOfFieldId))

proc generateSerializeProc(desc: NimNode): NimNode =
    let
        mtype = ident(getMessageName(desc))
        procName = postfix(ident("serialize"), "*")
        writer = ident("write" & getMessageName(desc))
        resultId = ident("result")

    result = quote do:
        proc `procName`(message: `mtype`): string =
            let
                ss = newStringStream()
                pbs = newProtobufStream(ss)
            `writer`(pbs, message)
            `resultId` = ss.data

proc generateDeserializeProc(desc: NimNode): NimNode =
    let
        mtype = ident(getMessageName(desc))
        procName = postfix(ident("new" & getMessageName(desc)), "*")
        reader = ident("read" & getMessageName(desc))
        resultId = ident("result")

    result = quote do:
        proc `procName`(data: string): `mtype` =
            let
                ss = newStringStream(data)
                pbs = newProtobufStream(ss)
            `resultId` = `reader`(pbs)

macro generateMessageProcs*(x: typed): typed =
    let
        desc = getImpl(symbol(x))

    result = newStmtList(
        generateNewMessageProc(desc),
    )

    for field in fields(desc):
        add(result, generateClearFieldProc(desc, field))
        add(result, generateHasFieldProc(desc, field))
        add(result, generateSetFieldProc(desc, field))

        if isRepeated(field):
            add(result, generateAddToFieldProc(desc, field))

    add(result, generateWriteMessageProc(desc))
    add(result, generateReadMessageProc(desc))
    add(result, generateSizeOfMessageProc(desc))
    add(result, generateSerializeProc(desc))
    add(result, generateDeserializeProc(desc))

    when defined(debug):
        hint(repr(result))

macro generateEnumType*(x: typed): typed =
    let
        impl = getImpl(symbol(x))
        name = $findColonExpr(impl, "name")[1]
        values = findColonExpr(impl, "values")[1]

    let enumTy = nnkEnumTy.newTree(newEmptyNode())

    for valueNode in values:
        let
            name = $findColonExpr(valueNode, "name")[1]
            number = findColonExpr(valueNode, "number")[1]

        add(enumTy, nnkEnumFieldDef.newTree(ident(name), number))

    result = newStmtList(nnkTypeSection.newTree(
        nnkTypeDef.newTree(
            nnkPragmaExpr.newTree(
                postfix(ident(name), "*"),
                nnkPragma.newTree(ident("pure"))
            ),
            newEmptyNode(),
            enumTy
        )
    ))

    when defined(debug):
        hint(repr(result))

macro generateEnumProcs*(x: typed): typed =
    let
        impl = getImpl(symbol(x))
        name = $findColonExpr(impl, "name")[1]
        nameId = ident(name)
        values = findColonExpr(impl, "values")[1]
        readProc = postfix(ident("read" & name), "*")
        writeProc = postfix(ident("write" & name), "*")
        sizeProc = postfix(ident("sizeOf" & name), "*")
        resultId = ident("result")

    result = newStmtList()

    add(result, quote do:
        proc `readProc`(stream: ProtobufStream): `nameId` =
            `resultId` = `nameId`(readUInt32(stream))

        proc `writeProc`(stream: ProtobufStream, value: `nameId`) =
            writeEnum(stream, value)

        proc `sizeProc`(value: `nameId`): uint64 =
            `resultId` = sizeOfUInt32(uint32(value))
    )

    when defined(debug):
        hint(repr(result))
