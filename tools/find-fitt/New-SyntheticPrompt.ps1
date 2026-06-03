<#
.SYNOPSIS
Generate a long synthetic text prompt of approximately N tokens for fitt testing.
#>
function New-SyntheticPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TokenCount,
        [Parameter(Mandatory)][string]$OutputFile,
        [int]$Seed = 42,
        [ValidateSet('lorem','wikipedia','code','shakespeare')]
        [string]$Style = 'lorem'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $styleParagraphs = Get-StyleParagraphs -Style $Style
    if (-not $styleParagraphs -or $styleParagraphs.Count -eq 0) {
        throw "No paragraphs defined for style '$Style'"
    }

    $charTarget = $TokenCount * 4
    $rng = [System.Random]::new($Seed)
    $sb = [System.Text.StringBuilder]::new($charTarget + 4096)

    while ($sb.Length -lt $charTarget) {
        $idx = $rng.Next(0, $styleParagraphs.Count)
        [void]$sb.AppendLine($styleParagraphs[$idx])
        [void]$sb.AppendLine()
    }

    try {
        [System.IO.File]::WriteAllText($OutputFile, $sb.ToString())
    } catch {
        throw "Failed to write synthetic prompt to '$OutputFile': $($_.Exception.Message)"
    }
    Write-Host "Wrote ~$TokenCount tokens to $OutputFile"
}

function Get-StyleParagraphs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('lorem','wikipedia','code','shakespeare')]
        [string]$Style
    )

    $loremA = @"
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo. Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt.
"@

    $loremB = @"
Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet, consectetur, adipisci velit, sed quia non numquam eius modi tempora incidunt ut labore et dolore magnam aliquam quaerat voluptatem. Ut enim ad minima veniam, quis nostrum exercitationem ullam corporis suscipit laboriosam, nisi ut aliquid ex ea commodi consequatur. Quis autem vel eum iure reprehenderit qui in ea voluptate velit esse quam nihil molestiae consequatur, vel illum qui dolorem eum fugiat quo voluptas nulla pariatur. At vero eos et accusamus et iusto odio dignissimos ducimus qui blanditiis praesentium voluptatum deleniti atque corrupti quos dolores et quas molestias excepturi sint occaecati cupiditate non provident, similique sunt in culpa qui officia deserunt mollitia animi, id est laborum et dolorum fuga.
"@

    $loremC = @"
Et harum quidem rerum facilis est et expedita distinctio. Nam libero tempore, cum soluta nobis est eligendi optio cumque nihil impedit quo minus id quod maxime placeat facere possimus, omnis voluptas assumenda est, omnis dolor repellendus. Temporibus autem quibusdam et aut officiis debitis aut rerum necessitatibus saepe eveniet ut et voluptates repudiandae sint et molestiae non recusandae. Itaque earum rerum hic tenetur a sapiente delectus, ut aut reiciendis voluptatibus maiores alias consequatur aut perferendis doloribus asperiores repellat. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
"@

    $wikipediaA = @"
The history of computing predates the invention of the modern digital computer by centuries. Mechanical aids to calculation have been used since antiquity, with the abacus being one of the earliest known computing devices. The development of more sophisticated computational machinery emerged gradually through the work of mathematicians and engineers across many centuries. Charles Babbage designed the Analytical Engine in the 1830s, which incorporated many features found in modern computers including conditional branching, loops, and memory separation from processing. Ada Lovelace, who wrote what is often considered the first algorithm intended for processing on a machine, recognized the broader potential of such devices beyond mere calculation. Throughout the twentieth century, the field evolved rapidly from vacuum tubes to transistors, from transistors to integrated circuits, and from single-user mainframes to distributed networks spanning the globe. The invention of the microprocessor in the 1970s made personal computing possible, transforming society in ways that few technologies have ever matched.
"@

    $wikipediaB = @"
The architecture of modern computers follows the Von Neumann model, which describes a system with a processing unit that fetches instructions from memory, decodes them, and executes them sequentially. While modern processors implement extensive parallelism, branch prediction, and out-of-order execution, the underlying model remains substantially the same as the one described in 1945. Memory hierarchies cache frequently accessed data close to the processor, with multiple levels of cache bridging the latency gap between registers and main memory. Storage systems employ similar hierarchies, with solid-state drives providing intermediate performance between volatile memory and mechanical disks, while network-attached and cloud-based storage extend the model across geographic distances. Operating systems manage these resources, abstracting hardware complexity through layers of software that schedule processes, allocate memory, mediate access to peripherals, and provide interfaces for application programs.
"@

    $wikipediaC = @"
Programming languages have evolved alongside computer hardware, from low-level machine code and assembly languages through to high-level abstractions that allow programmers to express algorithms in terms closer to human reasoning. Compiled languages translate source code into native machine instructions at build time, while interpreted languages execute directly through a runtime system that may also compile to an intermediate bytecode form. Garbage-collected languages relieve programmers from manual memory management, trading some performance for safety and developer productivity. Functional programming languages emphasize immutable data and pure functions, enabling powerful optimizations and parallel execution. Type systems range from dynamic, where types are checked at runtime, to static, where types are verified at compile time, with rich systems supporting generics, algebraic data types, dependent types, and linear types. Modern software development relies on ecosystems of libraries, frameworks, and tools that automate testing, building, and deployment.
"@

    $codeA = @"
def process_dataset(input_path: str, output_path: str, batch_size: int = 32) -> int:
    """Process a large dataset in batches and write results to disk.

    This function reads records from the input file in configurable batch sizes,
    applies a transformation to each record, and writes the transformed records
    to the output file. It returns the total number of records processed,
    including those that were skipped due to validation errors or duplicate keys.

    Args:
        input_path: Path to the input file containing one record per line.
        output_path: Path to the output file where results will be written.
        batch_size: Number of records to process in memory at once.

    Returns:
        The total count of records successfully written to the output file.

    Raises:
        FileNotFoundError: If the input path does not exist.
        PermissionError: If the output path is not writable.
    """
    if not os.path.exists(input_path):
        raise FileNotFoundError(f"Input file not found: {input_path}")

    count = 0
    batch = []

    with open(input_path, 'r', encoding='utf-8') as infile, \
         open(output_path, 'w', encoding='utf-8') as outfile:
        for line in infile:
            record = parse_record(line)
            if record is None:
                continue

            batch.append(record)

            if len(batch) >= batch_size:
                count += flush_batch(batch, outfile)
                batch = []

        if batch:
            count += flush_batch(batch, outfile)

    return count
"@

    $codeB = @"
class BinarySearchTree:
    """A self-balancing binary search tree implementation.

    The tree maintains the invariant that for every node, all values in
    the left subtree are less than the node's value, and all values in
    the right subtree are greater. Insertions, deletions, and lookups
    run in O(log n) time on balanced trees, degrading to O(n) only in
    pathological cases. The class supports iteration in sorted order
    via an in-order traversal, and provides a method to visualize the
    tree structure for debugging purposes.
    """

    def __init__(self):
        self.root = None
        self.size = 0

    def insert(self, value):
        if self.root is None:
            self.root = self._Node(value)
        else:
            self._insert_into(self.root, value)
        self.size += 1

    def _insert_into(self, node, value):
        if value < node.value:
            if node.left is None:
                node.left = self._Node(value)
            else:
                self._insert_into(node.left, value)
        else:
            if node.right is None:
                node.right = self._Node(value)
            else:
                self._insert_into(node.right, value)

    def contains(self, value):
        return self._find(self.root, value) is not None
"@

    $codeC = @"
import asyncio
import logging
from typing import Awaitable, Iterable, List, TypeVar

T = TypeVar("T")
logger = logging.getLogger(__name__)


async def gather_with_concurrency(n: int, tasks: Iterable[Awaitable[T]]) -> List[T]:
    """Run awaitable tasks with bounded concurrency.

    Args:
        n: Maximum number of tasks to run simultaneously.
        tasks: Iterable of awaitables to execute.

    Returns:
        A list of results in the same order as the input tasks.
    """
    semaphore = asyncio.Semaphore(n)

    async def wrapped(coro):
        async with semaphore:
            return await coro

    return await asyncio.gather(*(wrapped(t) for t in tasks))


async def fetch_all(endpoints: List[str], timeout: float = 5.0) -> dict:
    """Fetch data from multiple HTTP endpoints concurrently."""
    import aiohttp

    async with aiohttp.ClientSession() as session:
        async def fetch(url: str) -> tuple:
            try:
                async with session.get(url, timeout=timeout) as resp:
                    return url, await resp.json()
            except Exception as e:
                logger.warning("fetch failed for %s: %s", url, e)
                return url, None

        results = await gather_with_concurrency(8, [fetch(u) for u in endpoints])
        return dict(results)
"@

    $shakespeareA = @"
To be, or not to be, that is the question: Whether 'tis nobler in the mind to suffer The slings and arrows of outrageous fortune, Or to take arms against a sea of troubles And by opposing end them. To die-to sleep, No more; and by a sleep to say we end The heart-ache and the thousand natural shocks That flesh is heir to: 'tis a consummation Devoutly to be wish'd. To die, to sleep; To sleep, perchance to dream-ay, there's the rub: For in that sleep of death what dreams may come, When we have shuffled off this mortal coil, Must give us pause. There's the respect That makes calamity of so long life.
"@

    $shakespeareB = @"
All the world's a stage, And all the men and women merely players; They have their exits and their entrances, And one man in his time plays many parts, His acts being seven ages. At first, the infant, Mewling and puking in the nurse's arms. Then the whining school-boy, with his satchel And shining morning face, creeping like snail Unwillingly to school. And then the lover, Sighing like furnace, with a woeful ballad Made to his mistress' eyebrow. Then a soldier, Full of strange oaths and bearded like the pard, Jealous in honour, sudden and quick in quarrel, Seeking the bubble reputation Even in the cannon's mouth.
"@

    $shakespeareC = @"
Now is the winter of our discontent Made glorious summer by this sun of York; And all the clouds that lour'd upon our house In the deep bosom of the ocean buried. Now are our brows bound with victorious wreaths; Our bruised arms hung up for monuments; Our stern alarums changed to merry meetings, Our dreadful marches to delightful measures. Grim-visaged war hath smooth'd his wrinkled front; And now, instead of mounting barbed steeds To fright the souls of fearful adversaries, He capers nimbly in a lady's chamber To the lascivious pleasing of a lute.
"@

    $shakespeareD = @"
Friends, Romans, countrymen, lend me your ears; I come to bury Caesar, not to praise him. The evil that men do lives after them; The good is oft interred with their bones; So let it be with Caesar. The noble Brutus Hath told you Caesar was ambitious: If it were so, it was a grievous fault, And grievously hath Caesar answer'd it. Here, under leave of Brutus and the rest, For Brutus is an honourable man, So are they all, all honourable men, Come I to speak in Caesar's funeral. He was my friend, faithful and just to me: But Brutus says he was ambitious; And Brutus is an honourable man.
"@

    switch ($Style) {
        'lorem'       { return ,@($loremA, $loremB, $loremC) }
        'wikipedia'   { return ,@($wikipediaA, $wikipediaB, $wikipediaC) }
        'code'        { return ,@($codeA, $codeB, $codeC) }
        'shakespeare' { return ,@($shakespeareA, $shakespeareB, $shakespeareC, $shakespeareD) }
    }
}
